import CryptoKit
import Darwin
import Foundation

public enum MeetingTemplateError: Error, LocalizedError, Equatable, Sendable {
    case resourcesUnavailable, alteredTemplate, invalidData, dataTooLarge
    case invalidOutput, outputExists, archiveFailed, malformedTemplate

    public var errorDescription: String? {
        switch self {
        case .resourcesUnavailable: "Не найден комплект шаблона протокола. Переустановите приложение."
        case .alteredTemplate: "Комплект шаблона изменён или повреждён. Экспорт остановлен."
        case .invalidData: "Данные протокола не соответствуют полям шаблона."
        case .dataTooLarge: "Данные протокола превышают предел экспорта. Разделите запись на части."
        case .invalidOutput: "Не удалось создать документ в выбранной папке."
        case .outputExists: "Документ с таким именем уже существует. Выберите новое имя."
        case .archiveFailed: "Не удалось собрать DOCX. Исходный шаблон не изменён."
        case .malformedTemplate: "Структура шаблона DOCX не соответствует справочнику полей."
        }
    }
}

private final class MeetingResourceMarker: NSObject {}

public enum MeetingTemplate {
    // ponytail: один согласованный шаблон, не универсальный движок Word.
    // Новая версия формы требует проверки структуры, хешей и тестов экспорта.
    static let hashes = [
        "template.docx": "8b4ffde7a7d09c6f3450b2de8667334fe79f544157553c3e81d77456b43807ff",
        "fields.json": "335c2d5bbec50a45bdebed56098adbbe71ba68e85fba7556fd16f49fc3ec1a61",
        "data.schema.json": "0a0f3e5f22df726d1fee0c8140d738becfe737e752522751abfcb16a5bbc0c5a",
    ]
    static let blockEdges = [
        "participants": ("participant_id", "speaker_label"),
        "topics": ("topic_id", "related_decision_action_ids"),
        "decisions": ("decision_id", "decision_source"),
        "actions": ("action_id", "action_source"),
        "open_issues": ("open_issue", "clarification_due"),
        "transcript_speakers": ("transcript_speaker_label", "speaker_identification_basis"),
        "transcript_utterances": ("utterance_id", "utterance_text"),
    ]
    static let maximumValueBytes = 1_000_000
    static let maximumDataBytes = 16_000_000
    static let maximumRows = 20_000

    public static func directory() throws -> URL {
        for host in [Bundle.main, Bundle(for: MeetingResourceMarker.self)] {
            if let directory = directory(in: host) { return directory }
        }
        throw MeetingTemplateError.resourcesUnavailable
    }

    static func directory(in host: Bundle) -> URL? {
        let roots = [host.resourceURL, host.bundleURL,
                     host.executableURL?.deletingLastPathComponent(),
                     host.bundleURL.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            let bundleURL = root.appendingPathComponent("IrizApp_IrizDictate.bundle", isDirectory: true)
            let resource = Bundle(url: bundleURL)?.resourceURL ?? bundleURL
            let directory = resource.appendingPathComponent("MeetingMinutes", isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("fields.json").path) {
                return directory
            }
        }
        return nil
    }

    struct FieldList: Decodable {
        struct Field: Decodable { let name: String; let group: String }
        let fields: [Field]
    }

    static func groups(in directory: URL) throws -> [String: Set<String>] {
        let raw = try verifiedFile("fields.json", in: directory)
        guard let list = try? JSONDecoder().decode(FieldList.self, from: raw), list.fields.count == 87,
              Set(list.fields.map(\.name)).count == 87 else { throw MeetingTemplateError.alteredTemplate }
        let groups = Dictionary(grouping: list.fields, by: \.group).mapValues { Set($0.map(\.name)) }
        guard groups["fields"]?.count == 38,
              Set(groups.keys) == Set(blockEdges.keys).union(["fields"]) else {
            throw MeetingTemplateError.alteredTemplate
        }
        return groups
    }

    public static func emptyData() throws -> MeetingMinutesData {
        let groups = try groups(in: directory())
        var fields = Dictionary(uniqueKeysWithValues: groups["fields", default: []].map { ($0, "не указано") })
        fields["approval_status"] = "черновик"
        return MeetingMinutesData(fields: fields, blocks: Dictionary(uniqueKeysWithValues: blockEdges.keys.map { ($0, []) }))
    }

    public static func validate(_ data: MeetingMinutesData) throws {
        try validate(data, groups: groups(in: directory()))
    }

    static func validate(_ data: MeetingMinutesData, groups: [String: Set<String>]) throws {
        guard Set(data.fields.keys) == groups["fields"], Set(data.blocks.keys) == Set(blockEdges.keys) else {
            throw MeetingTemplateError.invalidData
        }
        var bytes = 0
        var rowCount = 0
        func validateValue(_ value: String) throws {
            let size = value.utf8.count
            guard size <= maximumValueBytes else { throw MeetingTemplateError.dataTooLarge }
            bytes += size
            guard bytes <= maximumDataBytes else { throw MeetingTemplateError.dataTooLarge }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.unicodeScalars.allSatisfy({ scalar in
                      let code = scalar.value
                      return code == 9 || code == 10 || code == 13 ||
                          (code >= 0x20 && code <= 0xD7FF) ||
                          (code >= 0xE000 && code <= 0xFFFD) || (code >= 0x10000 && code <= 0x10FFFF)
                  }) else { throw MeetingTemplateError.invalidData }
        }
        for value in data.fields.values { try validateValue(value) }
        for (block, rows) in data.blocks {
            rowCount += rows.count
            guard rowCount <= maximumRows else { throw MeetingTemplateError.dataTooLarge }
            for row in rows {
                guard Set(row.keys) == groups[block] else { throw MeetingTemplateError.invalidData }
                for value in row.values { try validateValue(value) }
            }
        }
    }

    /// Строгая схема для структурированного вывода: пропуск реквизита не равен «не указано».
    public static func strictSchema() throws -> Data {
        let directory = try directory()
        let raw = try verifiedFile("data.schema.json", in: directory)
        guard var schema = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw MeetingTemplateError.alteredTemplate
        }
        func makeStrict(_ input: [String: Any]) -> [String: Any] {
            var value = input
            if let properties = value["properties"] as? [String: [String: Any]] {
                value["required"] = properties.keys.sorted()
                value["additionalProperties"] = false
                value["properties"] = properties.mapValues(makeStrict)
            }
            if let items = value["items"] as? [String: Any] { value["items"] = makeStrict(items) }
            if value["type"] as? String == "string" { value["minLength"] = 1 }
            return value
        }
        schema = makeStrict(schema)
        return try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
    }

    static func verifiedFile(_ name: String, in directory: URL) throws -> Data {
        guard let expected = hashes[name] else { throw MeetingTemplateError.alteredTemplate }
        let data = try regularFile(directory.appendingPathComponent(name), limit: 2_000_000)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw MeetingTemplateError.alteredTemplate }
        return data
    }

    static func regularFile(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL else { throw MeetingTemplateError.alteredTemplate }
        // FIFO должен дойти до fstat без ожидания писателя; для обычного файла флаг безвреден.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MeetingTemplateError.alteredTemplate }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw MeetingTemplateError.alteredTemplate }
        guard let data = try handle.read(upToCount: limit + 1), data.count <= limit,
              data.count == info.st_size else { throw MeetingTemplateError.alteredTemplate }
        return data
    }
}
