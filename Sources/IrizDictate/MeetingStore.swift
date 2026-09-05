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
    public static func save(audio: URL, protocolText: String, at date: Date = Date(),
                            title: String, in root: URL? = nil) throws -> MeetingArtifacts {
        let directory = try meetingDirectory(at: date, title: title, in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let audioCopy = directory.appendingPathComponent("audio." + audio.pathExtension)
        if FileManager.default.fileExists(atPath: audioCopy.path) {
            try FileManager.default.removeItem(at: audioCopy)
        }
        try FileManager.default.copyItem(at: audio, to: audioCopy)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioCopy.path)

        let transcript = directory.appendingPathComponent("protocol.md")
        try protocolText.write(to: transcript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path)

        return MeetingArtifacts(directory: directory, audio: audioCopy, transcript: transcript)
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
}
