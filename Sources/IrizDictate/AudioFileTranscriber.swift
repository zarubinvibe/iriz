// Расшифровка готового файла ТЕМ ЖЕ путём, что и живая диктовка.
//
// Здесь только обёртка над `TranscriptionWorker` — та же загрузка модели из
// локального кэша, та же проверка целостности, тот же рубильник офлайна первой
// строкой. Отличается только источник отсчётов: файл вместо микрофона.
//
// Движков с волны 2 ДВА, и выбирает владелец (REQ-08). Прежняя строка на этом
// месте обещала, что второго распознавателя «нет и не будет»; замер
// 03.09.2026 это обещание отменил.
import FluidAudio
import Foundation

/// Результат расшифровки одного файла.
public struct AudioFileTranscript: Sendable {
    /// Текст ровно так, как его отдал распознаватель. Словарь замен здесь не
    /// применяется: он живёт в настройках приложения и правит диктовку, а
    /// расшифровка чужой записи — не диктовка владельца.
    public let text: String
    /// Сколько заняло само распознавание, секунды.
    public let processingSeconds: Double
    public let audioSeconds: Double

    public init(text: String, processingSeconds: Double, audioSeconds: Double) {
        self.text = text
        self.processingSeconds = processingSeconds
        self.audioSeconds = audioSeconds
    }
}

public actor AudioFileTranscriber {
    private let worker = TranscriptionWorker()
    private var prepared = false
    private let engine: SpeechModelProfile
    private let initialPrompt: String?

    /// Движок задается вызывающим, а не берется из настроек здесь: расшифровка
    /// файла из CLI не обязана читать выбор владельца из его настроек.
    public init(engine: SpeechModelProfile = .multilingualV3, initialPrompt: String? = nil) {
        self.engine = engine
        self.initialPrompt = initialPrompt
    }

    /// Библиотека шлёт прогресс только на звуке длиннее одного окна модели
    /// (~15 с). На коротком файле поток спрашивать НЕЛЬЗЯ: сессия откроется и
    /// никогда не закроется, а следующий файл останется без прогресса.
    public static func reportsProgress(forSamples count: Int) -> Bool {
        count > ASRConstants.maxModelSamples
    }

    /// Греет модель. Возвращает, сколько это заняло.
    public func prepare() async throws -> Double {
        if prepared { return 0 }
        // Рубильник офлайна — ПЕРВОЙ строкой, как в DictationController.start().
        DownloadUtils.enforceOffline = true
        let hostile = detectedHostileRegistryEnvVars(in: ProcessInfo.processInfo.environment)
        if !hostile.isEmpty {
            log("WARNING: registry override env var(s) set: \(hostile.joined(separator: ", ")) — ignored, offline enforced")
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        try await worker.load(profile: engine)
        await worker.setInitialPrompt(initialPrompt)
        prepared = true
        return ProcessInfo.processInfo.systemUptime - startedAt
    }

    /// Поток «доля обработанного звука» от библиотеки. На часовой записи это
    /// единственный честный источник прогресса — всё остальное было бы
    /// выдумкой. `nil`, если модель ещё не загружена.
    public func progressStream() async -> AsyncThrowingStream<Double, Error>? {
        await worker.progressStream()
    }

    public func transcribe(_ audio: DecodedAudio,
                           language: DictationLanguage) async throws -> AudioFileTranscript {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = try await worker.transcribe(samples: audio.samples,
                                                 language: language,
                                                 requestedAt: startedAt)
        return AudioFileTranscript(
            text: result.text,
            processingSeconds: ProcessInfo.processInfo.systemUptime - startedAt,
            audioSeconds: audio.seconds
        )
    }
}
