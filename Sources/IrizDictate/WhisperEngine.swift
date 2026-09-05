// Кандидат в движки распознавания: Whisper large-v3 через whisper.cpp.
//
// Зачем второй движок. Замер 03.09.2026 (`bench/BENCH-CANDIDATES-2026-09-03.md`)
// показал, что Parakeet транслитерирует английские термины внутри русской фразы:
// `git rebase` слышится как «гид репейс», `MCP` как «Мсипи». На смешанной речи это
// 44,05 процента ошибок против 19,05 у этого движка с промтом. Взамен он в 11-15 раз
// медленнее, поэтому оба живут в одном бинарнике и выбираются переключателем (REQ-08).
//
// Офлайн (REQ-07) держится ЗДЕСЬ по построению, а не флагом: whisper.cpp не имеет
// сетевого кода вообще - загрузка идет через whisper_init_from_file_with_params, то
// есть обычный std::ifstream по пути на диске. Если файла нет, движок отказывает с
// причиной и НИЧЕГО не качает.
import Foundation
import whisper

/// Куда положена модель кандидата. Каталог рядом с моделями остальных движков,
/// вне репозитория: вес 3,1 ГБ, в git такому места нет.
func whisperModelCacheDirectory() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/iriz/Models/whisper", isDirectory: true)
}

func whisperModelURL(_ file: String = "ggml-large-v3.bin") -> URL {
    whisperModelCacheDirectory().appendingPathComponent(file)
}

/// Энкодер CoreML лежит рядом с моделью под именем, которое whisper.cpp ищет сам.
/// Его отсутствие НЕ ошибка: сборка идет с WHISPER_COREML_ALLOW_FALLBACK, и без
/// энкодера исполнение падает на Metal, а не ломается.
func whisperCoreMLEncoderURL(for modelFile: String = "ggml-large-v3.bin") -> URL {
    let base = modelFile.hasSuffix(".bin") ? String(modelFile.dropLast(4)) : modelFile
    return whisperModelCacheDirectory().appendingPathComponent("\(base)-encoder.mlmodelc")
}

/// Подсказка декодеру по умолчанию для ЖИВОЙ диктовки.
///
/// Без нее рычаг не работает там, где он нужнее всего: в приложении, а не в CLI.
/// Замер 03.09.2026 дал с этой строкой 19,05 процента ошибок на смешанной речи
/// против 26,19 без нее.
///
/// Терминов проверочного корпуса здесь НЕТ намеренно: строка задает СТИЛЬ
/// («латиница остается латиницей»), и выигрыш получен обобщением правила, а не
/// подсказкой ответов. Ворота `scripts/bench_leak_check.py` это сторожат.
/// Дописывать сюда свой словарь терминов можно, но тогда замер по корпусу
/// перестанет быть честным, и ворота покраснеют - это не запрет, а плата.
public let whisperDefaultInitialPrompt =
    "Смотрю logs в Kubernetes, деплою через Docker и правлю YAML в CI pipeline."

enum WhisperEngineError: LocalizedError {
    case modelMissing(URL)
    case contextFailed(URL)
    case transcribeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .modelMissing(url):
            return "Модель Whisper не найдена: \(url.path). Движок ничего не качает - файл нужно положить руками."
        case let .contextFailed(url):
            return "Whisper не смог открыть модель: \(url.path)"
        case let .transcribeFailed(code):
            return "whisper_full вернул код \(code)"
        }
    }
}

/// Обертка над контекстом whisper.cpp. Не Sendable намеренно: контекст живет
/// внутри актора TranscriptionWorker и границу изоляции не пересекает.
final class WhisperEngine {
    private let ctx: OpaquePointer
    /// Подсказка декодеру. Рычаг под смешанную речь: замер дал 26,19 в 19,05 на
    /// срезе с английскими терминами. Промт задает СТИЛЬ, а не словарь ответов -
    /// в замере он не содержал ни одного термина корпуса, и выигрыш получен
    /// обобщением правила «латиница остается латиницей».
    var initialPrompt: String?

    init(modelURL: URL = whisperModelURL()) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperEngineError.modelMissing(modelURL)
        }
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw WhisperEngineError.contextFailed(modelURL)
        }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    /// Отсчеты - моно 16 кГц в диапазоне [-1, 1], как у остальных движков проекта.
    func transcribe(samples: [Float], language: DictationLanguage) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.translate = false
        params.n_threads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))

        // strdup держит строки живыми на весь вызов whisper_full: параметры хранят
        // сырые указатели, и временный буфер Swift здесь освободился бы раньше.
        let langPtr = strdup(language.whisperCode)
        let promptPtr = initialPrompt.flatMap { $0.isEmpty ? nil : strdup($0) }
        defer { free(langPtr); free(promptPtr) }
        if let langPtr { params.language = UnsafePointer(langPtr) }
        if let promptPtr { params.initial_prompt = UnsafePointer(promptPtr) }

        let code = samples.withUnsafeBufferPointer {
            whisper_full(ctx, params, $0.baseAddress, Int32($0.count))
        }
        guard code == 0 else { throw WhisperEngineError.transcribeFailed(code) }

        var text = ""
        for segment in 0..<whisper_full_n_segments(ctx) {
            if let chunk = whisper_full_get_segment_text(ctx, segment) {
                text += String(cString: chunk)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension DictationLanguage {
    /// Код языка для whisper.
    ///
    /// У автоопределения код «auto», а НЕ nil, и это не придирка к букве.
    /// `whisper_full_default_params` подставляет язык «en» по умолчанию: не
    /// передав ничего, мы получали не автоопределение, а жёсткий английский.
    /// Русская речь при этом молча выходила английским текстом, и выглядело
    /// это как перевод, которого никто не просил. Поймано владельцем живьём
    /// 04.09.2026: «периодически он ровно то, что я говорил на русском, пишет
    /// на английском, и без всякого вызова агента».
    var whisperCode: String {
        switch self {
        case .auto: return "auto"
        default: return rawValue
        }
    }
}
