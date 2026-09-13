// Где живёт встреча: звук и расшифровка рядом.
//
// ЗДЕСЬ ПРОДУКТ НАРУШАЕТ СОБСТВЕННОЕ ПРАВИЛО, И ЭТО РЕШЕНИЕ ВЛАДЕЛЬЦА.
//
// В диктовке звук не сохраняется никогда: надиктованное - это черновик мысли,
// и держать его голосом значит держать то, чего человек не просил хранить.
// У встречи и судебного заседания наоборот: звук сохраняется ВМЕСТЕ с
// расшифровкой, потому что расшифровку нечем сверить, а заседание - это
// доказательство, к которому возвращаются через год.
//
// Два правила противоречат друг другу только на вид: у них разные поверхности,
// и ворота `scripts/meeting_storage_gate.sh` проверяют, что они не слились.
//
// Правовая рамка со слов владельца: заседание публично, запись законна без
// согласия сторон. Приложение законность не проверяет - оно хранит то, что
// записано, и говорит владельцу, где это лежит.
import Foundation
import Darwin

public enum MeetingStore {
    /// Дом встреч рядом с домом диктовок, но отдельной папкой: разные правила
    /// хранения не должны делить каталог, иначе однажды их сольют уборкой.
    public static func meetingsDirectory(in root: URL? = nil) throws -> URL {
        let supportRoot = try root ?? irizApplicationSupportDirectory()
        return supportRoot.appendingPathComponent("meetings", isDirectory: true)
    }

    /// Папка одной встречи. Имя - время начала: по нему встречи сортируются
    /// сами, без индекса, который может разъехаться с диском.
    public static func meetingDirectory(at date: Date, title: String,
                                        in root: URL? = nil) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let slug = meetingSlug(title)
        let name = slug.isEmpty ? formatter.string(from: date)
                                : "\(formatter.string(from: date))-\(slug)"
        return try meetingsDirectory(in: root).appendingPathComponent(name, isDirectory: true)
    }

    /// Сохранить встречу: звук и протокол в одной папке.
    ///
    /// Звук КОПИРУЕТСЯ, а не переносится. Файл принёс владелец, и распоряжаться
    /// чужим оригиналом приложение не имеет права: перенос означал бы, что
    /// запись пропала из папки, куда её положил человек.
    @discardableResult
    public static func save(audio inputAudio: URL, protocolText: String, at date: Date = Date(),
                            title: String, in root: URL? = nil,
                            source: MeetingSource? = nil) throws -> MeetingArtifacts {
        let manager = FileManager.default
        guard inputAudio.isFileURL else { throw MeetingArchiveError.invalidArchive }
        let audio = inputAudio.resolvingSymlinksInPath()
        guard isRegular(audio) else { throw MeetingArchiveError.invalidArchive }
        let base = try meetingDirectory(at: date, title: title, in: root)
        let identifier = UUID().uuidString.lowercased()
        let directory = base.deletingLastPathComponent()
            .appendingPathComponent(base.lastPathComponent + "-" + identifier, isDirectory: true)
        let staging = base.deletingLastPathComponent()
            .appendingPathComponent(".saving-" + identifier, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // Новый архив появляется только целиком. Старые записи, в том числе с
        // тем же названием и временем, никогда не служат временным каталогом.
        defer { try? manager.removeItem(at: staging) }
        let audioName = "audio." + audio.pathExtension
        let audioCopy = staging.appendingPathComponent(audioName)
        try manager.copyItem(at: audio, to: audioCopy)
        guard isRegular(audioCopy) else { throw MeetingArchiveError.invalidArchive }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioCopy.path)

        let transcript = staging.appendingPathComponent("protocol.md")
        try protocolText.write(to: transcript, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path)
        if let source {
            try writeJSON(source, to: staging.appendingPathComponent("meeting-source.json"))
        }
        try manager.moveItem(at: staging, to: directory)

        return MeetingArtifacts(directory: directory,
                                audio: directory.appendingPathComponent(audioName),
                                transcript: directory.appendingPathComponent("protocol.md"),
                                source: source == nil ? nil : directory.appendingPathComponent("meeting-source.json"))
    }

    /// Каждое заполнение — новая версия. Отказ не меняет ни исходную запись,
    /// ни предыдущий DOCX; JSON и DOCX становятся видны одновременно.
    public static func exportMinutes(_ data: MeetingMinutesData, for artifacts: MeetingArtifacts,
                                     filled: Bool) throws -> MeetingArtifacts {
        try Task.checkCancellation()
        try MeetingTemplate.validate(data)
        guard isDirectory(artifacts.directory), let sourceURL = artifacts.source,
              isRegular(sourceURL), sourceURL.deletingLastPathComponent() == artifacts.directory else {
            throw MeetingArchiveError.invalidArchive
        }
        let identifier = UUID().uuidString.lowercased()
        let staging = artifacts.directory.appendingPathComponent(".export-" + identifier, isDirectory: true)
        let destination = artifacts.directory.appendingPathComponent("minutes-" + identifier, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        try writeJSON(data, to: staging.appendingPathComponent("meeting-data.json"))
        try MeetingDOCXExporter.export(data, to: staging.appendingPathComponent("meeting-minutes.docx"))
        try Task.checkCancellation()
        let notes = clarificationText(data, filled: filled)
        let notesURL = staging.appendingPathComponent("clarifications.txt")
        try Data(notes.utf8).write(to: notesURL, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notesURL.path)
        try writeJSON(ExportReceipt(createdAt: Date().timeIntervalSince1970, filled: filled),
                      to: staging.appendingPathComponent("export.json"))
        // Граница коммита: до неё отмена удалит только нашу staging-копию.
        // После успешного rename возвращаем опубликованный результат.
        try Task.checkCancellation()
        try manager.moveItem(at: staging, to: destination)
        return withExport(artifacts, directory: destination, filled: filled)
    }

    public static func loadSource(for artifacts: MeetingArtifacts) throws -> MeetingSource {
        guard isDirectory(artifacts.directory), let url = artifacts.source,
              url.deletingLastPathComponent() == artifacts.directory else {
            throw MeetingArchiveError.invalidArchive
        }
        return try readJSON(MeetingSource.self, from: url, limit: 32 * 1024 * 1024)
    }

    /// Архив переживает перезапуск приложения; незаконченные staging не видны.
    public static func recent(in root: URL? = nil) throws -> [MeetingArtifacts] {
        let parent = try meetingsDirectory(in: root)
        guard FileManager.default.fileExists(atPath: parent.path) else { return [] }
        guard isDirectory(parent) else { throw MeetingArchiveError.invalidArchive }
        let manager = FileManager.default
        let directories = try manager.contentsOfDirectory(at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { isDirectory($0) }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        return directories.prefix(50).compactMap { directory in
            guard let contents = try? manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]),
                  let audio = contents.first(where: { $0.lastPathComponent.hasPrefix("audio.") && isRegular($0) }) else { return nil }
            let transcript = directory.appendingPathComponent("protocol.md")
            guard isRegular(transcript) else { return nil }
            let source = directory.appendingPathComponent("meeting-source.json")
            let base = MeetingArtifacts(directory: directory, audio: audio, transcript: transcript,
                                        source: isRegular(source) ? source : nil)
            let versions = contents.filter { $0.lastPathComponent.hasPrefix("minutes-") && isDirectory($0) }
                .compactMap { url -> (URL, ExportReceipt)? in
                    guard let receipt = try? readJSON(ExportReceipt.self, from: url.appendingPathComponent("export.json"), limit: 4096),
                          ["meeting-data.json", "meeting-minutes.docx", "clarifications.txt"].allSatisfy({ isRegular(url.appendingPathComponent($0)) }) else { return nil }
                    return (url, receipt)
                }.sorted { $0.1.createdAt > $1.1.createdAt }
            guard let latest = versions.first else { return base }
            return withExport(base, directory: latest.0, filled: latest.1.filled)
        }
    }

    private struct ExportReceipt: Codable {
        // ISO8601 без долей секунды теряет порядок двух быстрых экспортов.
        let createdAt: Double
        let filled: Bool
    }

    private static func withExport(_ base: MeetingArtifacts, directory: URL, filled: Bool) -> MeetingArtifacts {
        MeetingArtifacts(directory: base.directory, audio: base.audio, transcript: base.transcript,
                         source: base.source, minutes: directory.appendingPathComponent("meeting-minutes.docx"),
                         data: directory.appendingPathComponent("meeting-data.json"),
                         clarifications: directory.appendingPathComponent("clarifications.txt"), minutesFilled: filled)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, from url: URL, limit: Int) throws -> T {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw MeetingArchiveError.invalidArchive }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0, status.st_size <= limit else { throw MeetingArchiveError.invalidArchive }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw MeetingArchiveError.invalidArchive }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func isRegular(_ url: URL) -> Bool {
        guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return value.isRegularFile == true && value.isSymbolicLink != true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let value = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return value.isDirectory == true && value.isSymbolicLink != true
    }

    private static func clarificationText(_ data: MeetingMinutesData, filled: Bool) -> String {
        var lines = [filled ? "Черновик протокола. Не согласован." : "Протокол не заполнен агентом. Сохранены расшифровка и форма с неизвестными сведениями.",
                     "Проверьте расшифровку по аудио, имена, даты, решения и поручения. Автоматическое распознавание может ошибаться."]
        func uncertain(_ value: String) -> Bool {
            let text = value.lowercased()
            return ["не указано", "требует уточнения", "не определ", "не установ", "не провер"].contains { text.contains($0) }
        }
        for key in data.fields.keys.sorted() where uncertain(data.fields[key] ?? "") {
            lines.append("\(key): \(data.fields[key] ?? "")")
        }
        for group in data.blocks.keys.sorted() where !group.hasPrefix("transcript_") {
            for (index, row) in (data.blocks[group] ?? []).enumerated() {
                for key in row.keys.sorted() where uncertain(row[key] ?? "") {
                    lines.append("\(group)[\(index + 1)].\(key): \(row[key] ?? "")")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Имя папки из названия встречи: латиница и цифры, остальное в дефис.
    /// Кириллица в путях уже стоила этому дому отдельного разбора, и здесь она
    /// не нужна - название целиком лежит внутри протокола.
    static func meetingSlug(_ title: String) -> String {
        let allowed = title.lowercased().map { character -> Character in
            if character.isLetter, character.isASCII { return character }
            if character.isNumber { return character }
            return "-"
        }
        return String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .prefix(6)
            .joined(separator: "-")
    }
}

/// Что осталось на диске после встречи. Оба поля обязательны: встреча без
/// звука или без расшифровки - это половина доказательства.
public struct MeetingArtifacts: Equatable, Sendable {
    public let directory: URL
    public let audio: URL
    public let transcript: URL
    public let source: URL?
    public let minutes: URL?
    public let data: URL?
    public let clarifications: URL?
    /// Заполнен агентом, но не проверен человеком и не согласован.
    public let minutesFilled: Bool

    public init(directory: URL, audio: URL, transcript: URL, source: URL? = nil,
                minutes: URL? = nil, data: URL? = nil, clarifications: URL? = nil,
                minutesFilled: Bool = false) {
        self.directory = directory
        self.audio = audio
        self.transcript = transcript
        self.source = source
        self.minutes = minutes
        self.data = data
        self.clarifications = clarifications
        self.minutesFilled = minutesFilled
    }
}

public enum MeetingArchiveError: String, Error, LocalizedError {
    case invalidArchive = "Архив встречи повреждён или недоступен. Исходные файлы не изменены."
    public var errorDescription: String? { rawValue }
}
