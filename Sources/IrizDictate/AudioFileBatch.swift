// Расшифровка готового файла или папки: РЕШЕНИЯ (что берём, куда пишем, когда
// отказываемся). Ни звука, ни модели здесь нет — это чистая часть, её и
// проверяют тесты.
//
// ЗАЧЕМ ЭТО ВООБЩЕ. Записанное заседание и голосовое клиента — единственный
// сценарий, где офлайн-распознавание работает без диктовки. Модель уже лежит
// на диске, сеть не нужна ни на одном шаге.
//
// ПРАВИЛО ОТКАЗА. Молчаливый пустой файл хуже отказа: если прочитать нечем
// или расшифровки не вышло, никакого .txt не появляется, а причина называется
// вслух.
import Foundation

/// Одна работа: откуда читаем звук, куда кладём расшифровку.
public struct AudioTranscriptionJob: Equatable, Sendable {
    public let source: URL
    public let destination: URL

    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }
}

/// Отказ на этапе разбора аргументов — до того, как тронут хоть один байт звука.
public enum AudioBatchPlanError: Error, Equatable {
    case pathNotFound(String)
    case pathNotReadable(String)
    case directoryHasNoAudio(String)
    case outputFileForManySources(String)
    case destinationExists(String)
    case destinationCollision(String)
    case destinationOverwritesSource(String)
    case unknownLanguage(String, allowed: [String])

    public var message: String {
        switch self {
        case .pathNotFound(let path):
            return "Не нашёл \(path)."
        case .pathNotReadable(let path):
            return "Нет прав на чтение \(path)."
        case .directoryHasNoAudio(let path):
            return """
                В папке \(path) нет ни одного файла со звуком. \
                Понимаю: \(AudioFileBatch.supportedExtensionsLabel).
                """
        case .outputFileForManySources(let path):
            return "Расшифровок несколько, а --output \(path) — это один файл. Укажите папку."
        case .destinationExists(let path):
            return "Расшифровка \(path) уже есть. Перезаписать — только с --force."
        case .destinationCollision(let path):
            return "Два файла дали бы одну и ту же расшифровку \(path). Разведите их по папкам."
        case .destinationOverwritesSource(let path):
            return "Расшифровка затёрла бы сам исходник \(path). Это точно не звук?"
        case .unknownLanguage(let value, let allowed):
            return "Не знаю язык «\(value)». Есть: \(allowed.joined(separator: ", "))."
        }
    }
}

public enum AudioFileBatch {
    /// Контейнеры, которые системный AVFoundation читает без единой сторонней
    /// библиотеки. Список нарочно закрытый: обещать `.ogg`, который система не
    /// декодирует, значит врать в справке.
    public static let supportedExtensions: Set<String> = [
        "aac", "aif", "aifc", "aiff", "caf", "flac",
        "m4a", "m4b", "m4v", "mov", "mp3", "mp4", "wav", "wave",
    ]

    public static var supportedExtensionsLabel: String {
        supportedExtensions.sorted().map { ".\($0)" }.joined(separator: ", ")
    }

    /// Расширение расшифровки. Простой текст: его открывает всё.
    public static let transcriptExtension = "txt"

    /// Что из имён файлов папки имеет смысл распознавать.
    /// Чистая функция над именами — папку читает вызывающий.
    ///
    /// Скрытые пропускаются (`.DS_Store` и хвосты синхронизации), порядок —
    /// как в Finder, чтобы «первый» в отчёте совпадал с первым на экране.
    public static func audioFileNames(in names: [String]) -> [String] {
        names
            .filter { name in
                guard !name.hasPrefix(".") else { return false }
                return supportedExtensions.contains((name as NSString).pathExtension.lowercased())
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Куда ляжет расшифровка: то же имя, расширение `.txt`.
    /// `directory == nil` — рядом с исходником.
    public static func destination(forSource source: URL, in directory: URL?) -> URL {
        let name = source.deletingPathExtension().lastPathComponent
        let folder = directory ?? source.deletingLastPathComponent()
        return folder.appendingPathComponent("\(name).\(transcriptExtension)", isDirectory: false)
    }

    /// Полный разбор аргументов в список работ.
    ///
    /// Одиночный файл берётся КАК ЕСТЬ, без проверки расширения: звук у
    /// владельца может называться как угодно, а «это не звук» честно скажет
    /// декодер. Фильтр расширений работает только на папке — там перебирать
    /// договоры и сканы никто не просил.
    public static func plan(inputPath: String,
                            outputPath: String? = nil,
                            force: Bool = false,
                            fileManager: FileManager = .default) throws -> [AudioTranscriptionJob] {
        let input = URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath)
        var inputIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: input.path, isDirectory: &inputIsDirectory) else {
            throw AudioBatchPlanError.pathNotFound(input.path)
        }
        guard fileManager.isReadableFile(atPath: input.path) else {
            throw AudioBatchPlanError.pathNotReadable(input.path)
        }

        let sources: [URL]
        if inputIsDirectory.boolValue {
            let names = (try? fileManager.contentsOfDirectory(atPath: input.path)) ?? []
            let picked = audioFileNames(in: names)
            guard !picked.isEmpty else {
                throw AudioBatchPlanError.directoryHasNoAudio(input.path)
            }
            sources = picked.map { input.appendingPathComponent($0, isDirectory: false) }
        } else {
            sources = [input]
        }

        let jobs = try makeJobs(sources: sources,
                                outputPath: outputPath,
                                fileManager: fileManager)
        try validate(jobs: jobs, force: force, fileManager: fileManager)
        return jobs
    }

    private static func makeJobs(sources: [URL],
                                 outputPath: String?,
                                 fileManager: FileManager) throws -> [AudioTranscriptionJob] {
        guard let outputPath else {
            return sources.map { AudioTranscriptionJob(source: $0, destination: destination(forSource: $0, in: nil)) }
        }
        let output = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)

        var outputIsDirectory: ObjCBool = false
        let outputExists = fileManager.fileExists(atPath: output.path, isDirectory: &outputIsDirectory)
        // Папка — если она уже папка или названа с косой чертой на конце.
        // Черту смотрим в ИСХОДНОЙ строке: expandingTildeInPath её срезает,
        // и «--output новая/» превращалось в файл с именем «новая».
        let wantsDirectory = (outputExists && outputIsDirectory.boolValue) || outputPath.hasSuffix("/")

        if wantsDirectory {
            return sources.map {
                AudioTranscriptionJob(source: $0, destination: destination(forSource: $0, in: output))
            }
        }
        guard sources.count == 1 else {
            throw AudioBatchPlanError.outputFileForManySources(output.path)
        }
        return [AudioTranscriptionJob(source: sources[0], destination: output)]
    }

    private static func validate(jobs: [AudioTranscriptionJob],
                                 force: Bool,
                                 fileManager: FileManager) throws {
        var seen = Set<String>()
        for job in jobs {
            let path = job.destination.standardizedFileURL.path
            guard path != job.source.standardizedFileURL.path else {
                throw AudioBatchPlanError.destinationOverwritesSource(job.source.path)
            }
            guard seen.insert(path).inserted else {
                throw AudioBatchPlanError.destinationCollision(path)
            }
            if !force, fileManager.fileExists(atPath: path) {
                throw AudioBatchPlanError.destinationExists(path)
            }
        }
    }
}
