// Хранилище расшифровок smltlk — плоские файлы, не база.
// Свой код (не донорский).
//
// ~/Library/Application Support/smltlk/dictations/<ГГГГ-ММ-ДД_ЧЧ-ММ-СС>/raw.txt
// Сырая расшифровка неприкосновенна: пишется один раз, не меняется никогда.
// В prompt-режиме рядом лежат prompt.md (проверяемый артефакт)
// и generated.txt (готовый промпт). inserted.txt по-прежнему значит только
// одно: текст фактически ушёл в поле.
import Foundation

/// Имена файлов надиктовки. Строкой их читают ещё и перечислитель промпт-режима
/// (Sources/IrizPrompt) и scripts/dedup_dictations.sh — там своя копия имени,
/// эти константы её не заменяют, а называют для своего модуля.
let DICTATION_RAW_FILE_NAME = "raw.txt"
let DICTATION_INSERTED_FILE_NAME = "inserted.txt"
let DICTATION_PROMPT_FILE_NAME = "prompt.md"
let DICTATION_GENERATED_PROMPT_FILE_NAME = "generated.txt"
/// Отклонённый проверкой промт и отчёт о том, какие пункты сказали НЕТ.
/// Имена нарочно не совпадают с принятыми: черновик, не прошедший ворота,
/// не имеет права однажды подхватиться как готовый.
let DICTATION_REJECTED_PROMPT_FILE_NAME = "prompt-rejected.md"
let DICTATION_REJECTED_REPORT_FILE_NAME = "verification.txt"
/// Тайминги токенов распознавателя (см. DictationTimings.swift).
let DICTATION_TIMINGS_FILE_NAME = "timings.json"

public enum DictationStore {
    /// Каталог со всеми надиктовками. `root` подменяется только тестами.
    public static func dictationsDirectory(in root: URL? = nil) throws -> URL {
        let supportRoot = try root ?? irizApplicationSupportDirectory()
        return supportRoot.appendingPathComponent("dictations", isDirectory: true)
    }

    /// Сохраняет сырую расшифровку и возвращает URL файла raw.txt.
    /// Файл — 0600 (каталог 0700), запись через приватный POSIX-путь донора.
    ///
    /// `root` подменяется только тестами: в живых данных владельца им делать
    /// нечего, поэтому проверка «сырьё легло байт в байт» идёт на временном
    /// каталоге, а не в ~/Library/Application Support/smltlk.
    @discardableResult
    static func save(rawText: String, at date: Date = Date(), in root: URL? = nil) throws -> URL {
        let supportRoot: URL
        if let root {
            supportRoot = root
        } else {
            supportRoot = try irizApplicationSupportDirectory()
        }
        let base = try dictationsDirectory(in: supportRoot)
        var dir = base.appendingPathComponent(timestampLabel(date), isDirectory: true)
        // Две диктовки в одну секунду не затирают друг друга.
        var suffix = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = base.appendingPathComponent("\(timestampLabel(date))-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let rawURL = dir.appendingPathComponent(DICTATION_RAW_FILE_NAME)
        try appendPrivateLogData(Data(rawText.utf8), to: rawURL)
        return rawURL
    }

    /// Кладёт рядом с сырьём то, что ФАКТИЧЕСКИ ушло в поле — после словаря
    /// замен и суффикса вставки. Без этого следующий этап (обучение на правках)
    /// не с чем сравнивать: правку диффят против вставленного, а не против
    /// сырья.
    ///
    /// Сырьё не трогается ни при каком исходе — это отдельный файл.
    ///
    /// Возвращает `false`, если файл уже есть: `appendPrivateLogData`
    /// ДОПИСЫВАЕТ, и второй вызов склеил бы две вставки в одну строку. Для
    /// raw.txt это безопасно (каталог всегда новый), для inserted.txt — нет.
    /// В лог отказ пишет вызывающий: хранилище о живом логе не знает.
    @discardableResult
    static func saveInsertedText(_ text: String, besideRawAt rawURL: URL) throws -> Bool {
        let url = rawURL
            .deletingLastPathComponent()
            .appendingPathComponent(DICTATION_INSERTED_FILE_NAME)
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try appendPrivateLogData(Data(text.utf8), to: url)
        return true
    }

    /// Кладёт рядом с сырьём тайминги токенов распознавателя.
    ///
    /// Отдельный файл, а не строка в raw.txt: сырьё неприкосновенно и остаётся
    /// байт в байт тем, что вернул распознаватель. Пустые тайминги не пишутся —
    /// файл без данных обещал бы замер, которого нет.
    ///
    /// Возвращает `false`, если писать нечего или имя уже занято:
    /// `appendPrivateLogData` ДОПИСЫВАЕТ, и второй вызов склеил бы два JSON
    /// в один нечитаемый файл.
    @discardableResult
    static func saveTokenTimings(_ timings: DictationTimings, besideRawAt rawURL: URL) throws -> Bool {
        guard !timings.isEmpty else { return false }
        let url = rawURL
            .deletingLastPathComponent()
            .appendingPathComponent(DICTATION_TIMINGS_FILE_NAME)
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try appendPrivateLogData(try timings.encoded(), to: url)
        return true
    }

    /// Сохраняет проверяемый артефакт и готовый промпт отдельно.
    /// История читает `generated.txt` напрямую и никогда не парсит `prompt.md`.
    /// Если хотя бы одно имя занято, ничего не дописывает и не затирает.
    @discardableResult
    /// Промт, который не прошёл проверку. Кладётся рядом с сырьём под именем,
    /// которое НЕЛЬЗЯ спутать с принятым: приложение читает как готовый только
    /// `prompt.md`, и отклонённый черновик не должен однажды подхватиться вместо него.
    ///
    /// Ошибки записи глотаются намеренно и это единственное место, где так можно:
    /// вызов стоит на пути отказа, и уронить его из-за неудачного сохранения
    /// диагностики значит заменить понятную ошибку непонятной.
    static func saveRejectedPromptArtifacts(
        artifact: String,
        report: String,
        besideRawAt rawURL: URL,
        writer: (Data, URL) throws -> Void = { data, url in
            try appendPrivateLogData(data, to: url)
        }
    ) {
        let directory = rawURL.deletingLastPathComponent()
        let artifactURL = directory.appendingPathComponent(DICTATION_REJECTED_PROMPT_FILE_NAME)
        let reportURL = directory.appendingPathComponent(DICTATION_REJECTED_REPORT_FILE_NAME)
        guard !FileManager.default.fileExists(atPath: artifactURL.path) else { return }
        try? writer(Data(artifact.utf8), artifactURL)
        try? writer(Data(report.utf8), reportURL)
    }

    static func savePromptArtifacts(
        artifact: String,
        generatedPrompt: String,
        besideRawAt rawURL: URL,
        writer: (Data, URL) throws -> Void = { data, url in
            try appendPrivateLogData(data, to: url)
        }
    ) throws -> Bool {
        let directory = rawURL.deletingLastPathComponent()
        let artifactURL = directory.appendingPathComponent(DICTATION_PROMPT_FILE_NAME)
        let generatedURL = directory.appendingPathComponent(DICTATION_GENERATED_PROMPT_FILE_NAME)
        guard !FileManager.default.fileExists(atPath: artifactURL.path),
              !FileManager.default.fileExists(atPath: generatedURL.path) else { return false }
        do {
            try writer(Data(artifact.utf8), artifactURL)
            try writer(Data(generatedPrompt.utf8), generatedURL)
        } catch {
            // Оба имени были свободны на входе. Убираем только то, что мог
            // частично создать этот же вызов. raw.txt и inserted.txt не трогаем.
            try? FileManager.default.removeItem(at: artifactURL)
            try? FileManager.default.removeItem(at: generatedURL)
            throw error
        }
        return true
    }

    private static func timestampLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date)
    }
}
