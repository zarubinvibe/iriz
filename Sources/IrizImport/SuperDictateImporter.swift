import Foundation
import IrizCore

public struct SuperDictateTranscript: Decodable, Sendable {
    public let text: String
}

public enum SuperDictateImportResult: Equatable, Sendable {
    case imported(settings: Int, dictations: Int)
    case nothingToImport
}

public struct SuperDictateImporter {
    public static let sourceDomain = "com.local.superdictate"
    public static let completionKey = "ru.smltlk.superDictateImportCompleted"

    private let source: UserDefaults?
    private let destination: UserDefaults
    private let dictationsDirectory: URL
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    public init() {
        self.init(
            source: UserDefaults(suiteName: Self.sourceDomain),
            destination: .standard,
            // Каталог адресуется общей функцией, а не собирается тут: своя
            // сборка пути пережила переименование продукта и продолжала бы
            // складывать импортированные надиктовки в мёртвый каталог.
            dictationsDirectory: irizApplicationSupportDirectoryURL()
                .appendingPathComponent("dictations", isDirectory: true)
        )
    }

    public init(
        source: UserDefaults?,
        destination: UserDefaults,
        dictationsDirectory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.source = source
        self.destination = destination
        self.dictationsDirectory = dictationsDirectory
        self.now = now
        self.fileManager = fileManager
    }

    public func run() -> SuperDictateImportResult {
        migrateSmltlkPrivateFilePermissionsOnce(
            at: dictationsDirectory.deletingLastPathComponent(),
            defaults: destination,
            fileManager: fileManager,
            log: Self.log
        )

        guard !destination.bool(forKey: Self.completionKey), let source else {
            return .nothingToImport
        }

        let settings = Self.settingKeys.compactMap { sourceKey, destinationKey in
            source.object(forKey: sourceKey).map { (destinationKey, $0) }
        }
        let transcripts = source.data(forKey: "recent_transcript_entries_v1")
            .flatMap { try? Self.decodeTranscripts(from: $0) } ?? []

        guard !settings.isEmpty || !transcripts.isEmpty else {
            return .nothingToImport
        }

        do {
            let importedDictations = try write(transcripts)
            var importedSettings = 0
            for (key, value) in settings where destination.object(forKey: key) == nil {
                destination.set(value, forKey: key)
                importedSettings += 1
            }
            destination.set(true, forKey: Self.completionKey)
            guard importedSettings > 0 || importedDictations > 0 else {
                return .nothingToImport
            }
            return .imported(settings: importedSettings, dictations: importedDictations)
        } catch {
            Self.log("SuperDictate import failed: \(error.localizedDescription)")
            return .nothingToImport
        }
    }

    public static func decodeTranscripts(from data: Data) throws -> [SuperDictateTranscript] {
        try JSONDecoder().decode([SuperDictateTranscript].self, from: data)
    }

    private func write(_ transcripts: [SuperDictateTranscript]) throws -> Int {
        guard !transcripts.isEmpty else { return 0 }
        try createPrivateDirectory(
            at: dictationsDirectory,
            withIntermediateDirectories: true,
            fileManager: fileManager
        )

        var remainingExistingTexts = try existingTranscriptTextCounts()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let start = now()
        var imported = 0

        for (offset, transcript) in transcripts.enumerated() {
            if let count = remainingExistingTexts[transcript.text], count > 0 {
                remainingExistingTexts[transcript.text] = count - 1
                continue
            }

            let date = start.addingTimeInterval(-Double(offset))
            let baseDirectory = dictationsDirectory.appendingPathComponent(
                formatter.string(from: date),
                isDirectory: true
            )
            let directory = try uniqueDirectory(startingAt: baseDirectory)
            try createPrivateDirectory(
                at: directory,
                withIntermediateDirectories: false,
                fileManager: fileManager
            )
            try appendPrivateLogData(
                Data(transcript.text.utf8),
                to: directory.appendingPathComponent("raw.txt")
            )
            imported += 1
        }

        return imported
    }

    private func existingTranscriptTextCounts() throws -> [String: Int] {
        guard fileManager.fileExists(atPath: dictationsDirectory.path) else {
            return [:]
        }

        guard let enumerator = fileManager.enumerator(
            at: dictationsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return [:]
        }
        var counts: [String: Int] = [:]
        for case let url as URL in enumerator where url.lastPathComponent == "raw.txt" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            counts[text, default: 0] += 1
        }
        return counts
    }

    private func uniqueDirectory(startingAt base: URL) throws -> URL {
        var directory = base
        var suffix = 2
        while fileManager.fileExists(atPath: directory.path) {
            directory = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return directory
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static let settingKeys: [(String, String)] = [
        ("hotkey_keycode", "ru.smltlk.dictationHotkeyKeyCode"),
        ("hotkey_modifiers", "ru.smltlk.dictationHotkeyModifiers"),
        ("enter_hotkey_keycode", "ru.smltlk.enterHotkeyKeyCode"),
        ("enter_hotkey_modifiers", "ru.smltlk.enterHotkeyModifiers"),
        ("history_hotkey_keycode", "ru.smltlk.historyHotkeyKeyCode"),
        ("history_hotkey_modifiers", "ru.smltlk.historyHotkeyModifiers"),
        ("enter_delay_milliseconds_v1", "ru.smltlk.enterDelayMilliseconds"),
        ("primary_completion_behavior_v1", "ru.smltlk.primaryCompletionBehavior"),
        ("interface_language", "ru.smltlk.interfaceLanguage"),
    ]
}
