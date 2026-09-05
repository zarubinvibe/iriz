import Darwin
import Foundation
import Testing
@testable import IrizCore
@testable import IrizImport

struct SuperDictateImporterTests {
    private struct SyntheticFixture: Decodable {
        let id: String
        let synthetic: Bool
        let text: String
    }

    @Test func parsesSyntheticFixtureWithoutChangingText() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/transcripts.json")
        let data = try Data(contentsOf: fixture)
        let entries = try JSONDecoder().decode([SyntheticFixture].self, from: data)

        let transcripts = try SuperDictateImporter.decodeTranscripts(from: data)

        #expect(entries.count == 12)
        #expect(entries.allSatisfy { $0.synthetic })
        #expect(entries.allSatisfy { $0.id.hasPrefix("synthetic-") })
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(transcripts.count == entries.count)
        #expect(transcripts.map(\.text) == entries.map(\.text))
        let longest = try #require(transcripts.max { $0.text.count < $1.text.count })
        #expect(String(data: Data(longest.text.utf8), encoding: .utf8) == longest.text)
    }

    @Test func secondRunDoesNotCreateDuplicates() throws {
        let id = UUID().uuidString
        let sourceName = "ru.smltlk.tests.source.\(id)"
        let destinationName = "ru.smltlk.tests.destination.\(id)"
        let source = try #require(UserDefaults(suiteName: sourceName))
        let destination = try #require(UserDefaults(suiteName: destinationName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iriz-import-\(id)/iriz/dictations", isDirectory: true)
        defer {
            source.removePersistentDomain(forName: sourceName)
            destination.removePersistentDomain(forName: destinationName)
            // cfprefsd дописывает plist обратно после выхода процесса — сносим и файлы,
            // иначе каждый прогон оставляет мусор в ~/Library/Preferences владельца.
            for suite in [sourceName, destinationName] {
                try? FileManager.default.removeItem(at: FileManager.default
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Preferences/\(suite).plist"))
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let entries = [
            ["text": "Свежая запись"],
            ["text": "Старая запись"],
        ]
        source.set(try JSONSerialization.data(withJSONObject: entries), forKey: "recent_transcript_entries_v1")
        source.set(54, forKey: "hotkey_keycode")
        source.set(0, forKey: "hotkey_modifiers")
        destination.set(55, forKey: "ru.smltlk.dictationHotkeyKeyCode")
        let importer = SuperDictateImporter(
            source: source,
            destination: destination,
            dictationsDirectory: directory,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        #expect(importer.run() == .imported(settings: 1, dictations: 2))
        #expect(destination.integer(forKey: "ru.smltlk.dictationHotkeyKeyCode") == 55)
        let firstRunFiles = try rawFiles(in: directory)
        #expect(firstRunFiles.count == 2)
        #expect(importer.run() == .nothingToImport)
        #expect(try rawFiles(in: directory) == firstRunFiles)
    }

    @Test func importCreatesPrivateDirectoriesAndRawFiles() throws {
        let id = UUID().uuidString
        let sourceName = "ru.smltlk.tests.source.\(id)"
        let destinationName = "ru.smltlk.tests.destination.\(id)"
        let source = try #require(UserDefaults(suiteName: sourceName))
        let destination = try #require(UserDefaults(suiteName: destinationName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iriz-import-private-\(id)/iriz/dictations", isDirectory: true)
        defer {
            cleanup(defaults: source, name: sourceName)
            cleanup(defaults: destination, name: destinationName)
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }

        source.set(
            try JSONSerialization.data(withJSONObject: [["text": "Процессуальный текст"]]),
            forKey: "recent_transcript_entries_v1"
        )
        let importer = SuperDictateImporter(
            source: source,
            destination: destination,
            dictationsDirectory: directory,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        #expect(importer.run() == .imported(settings: 0, dictations: 1))
        let raw = try #require(try rawFileURLs(in: directory).first)
        #expect(try permissions(of: directory.deletingLastPathComponent()) == 0o700)
        #expect(try permissions(of: directory) == 0o700)
        #expect(try permissions(of: raw.deletingLastPathComponent()) == 0o700)
        #expect(try permissions(of: raw) == 0o600)
    }

    @Test func permissionMigrationIsIdempotentAndPreservesBytes() throws {
        let id = UUID().uuidString
        let destinationName = "ru.smltlk.tests.destination.\(id)"
        let destination = try #require(UserDefaults(suiteName: destinationName))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iriz-permissions-\(id)/iriz", isDirectory: true)
        let dictation = root.appendingPathComponent("dictations/old", isDirectory: true)
        let raw = dictation.appendingPathComponent("raw.txt")
        defer {
            cleanup(defaults: destination, name: destinationName)
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: dictation,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let original = Data("Личная запись".utf8)
        try original.write(to: raw)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dictation.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: raw.path)

        migrateSmltlkPrivateFilePermissionsOnce(at: root, defaults: destination)
        migrateSmltlkPrivateFilePermissionsOnce(at: root, defaults: destination)

        #expect(destination.bool(forKey: SMLTLK_PRIVATE_FILE_PERMISSION_MIGRATION_KEY))
        #expect(try permissions(of: root) == 0o700)
        #expect(try permissions(of: dictation) == 0o700)
        #expect(try permissions(of: raw) == 0o600)
        #expect(try Data(contentsOf: raw) == original)
        #expect(FileManager.default.fileExists(atPath: raw.path))
    }

    /// Рекурсивная смена прав не должна уметь уйти за пределы своего каталога.
    /// Замерено вживую: пока предохранителя не было, миграция с корнем в общем
    /// temp пошла менять права com.apple.financed, proactived и
    /// searchpartyuseragent. Спасло только то, что система не дала.
    @Test func migrationRefusesRootThatIsNotOurs() throws {
        let id = UUID().uuidString
        let destinationName = "ru.smltlk.tests.destination.\(id)"
        let destination = try #require(UserDefaults(suiteName: destinationName))
        let alien = FileManager.default.temporaryDirectory
            .appendingPathComponent("someone-elses-dir-\(id)", isDirectory: true)
        let victim = alien.appendingPathComponent("data.txt")
        defer {
            cleanup(defaults: destination, name: destinationName)
            try? FileManager.default.removeItem(at: alien)
        }

        try FileManager.default.createDirectory(
            at: alien,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try Data("чужие данные".utf8).write(to: victim)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: victim.path)

        migrateSmltlkPrivateFilePermissionsOnce(at: alien, defaults: destination)

        // Права чужого каталога и файла не изменились…
        #expect(try permissions(of: alien) == 0o755)
        #expect(try permissions(of: victim) == 0o644)
        // …и отметка «миграция выполнена» не поставлена: работы не было.
        #expect(destination.bool(forKey: SMLTLK_PRIVATE_FILE_PERMISSION_MIGRATION_KEY) == false)
    }

    @Test func lostCompletionKeyDoesNotImportExistingTextsAgain() throws {
        let id = UUID().uuidString
        let sourceName = "ru.smltlk.tests.source.\(id)"
        let destinationName = "ru.smltlk.tests.destination.\(id)"
        let source = try #require(UserDefaults(suiteName: sourceName))
        let destination = try #require(UserDefaults(suiteName: destinationName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iriz-import-lost-key-\(id)/iriz/dictations", isDirectory: true)
        defer {
            cleanup(defaults: source, name: sourceName)
            cleanup(defaults: destination, name: destinationName)
            try? FileManager.default.removeItem(at: directory)
        }

        let entries = [
            ["text": "Первый текст"],
            ["text": "Второй текст"],
        ]
        source.set(try JSONSerialization.data(withJSONObject: entries), forKey: "recent_transcript_entries_v1")
        let first = SuperDictateImporter(
            source: source,
            destination: destination,
            dictationsDirectory: directory,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        #expect(first.run() == .imported(settings: 0, dictations: 2))
        let firstRunFiles = try rawFiles(in: directory)

        destination.removeObject(forKey: SuperDictateImporter.completionKey)
        let second = SuperDictateImporter(
            source: source,
            destination: destination,
            dictationsDirectory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        #expect(second.run() == .nothingToImport)
        #expect(destination.bool(forKey: SuperDictateImporter.completionKey))
        #expect(try rawFiles(in: directory) == firstRunFiles)
    }

    private func rawFiles(in directory: URL) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix("/raw.txt") }
            .sorted()
    }

    private func rawFileURLs(in directory: URL) throws -> [URL] {
        try rawFiles(in: directory)
            .map { directory.appendingPathComponent($0) }
    }

    /// `Darwin.stat(path:)` не вызвать: имя `stat` в этом контексте разрешается
    /// в структуру, а не в функцию. FileManager даёт то же число без возни с POSIX.
    private func permissions(of url: URL) throws -> mode_t {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber else {
            throw POSIXError(.EIO)
        }
        return mode_t(mode.uint16Value) & 0o777
    }

    private func cleanup(defaults: UserDefaults, name: String) {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist"))
    }
}
