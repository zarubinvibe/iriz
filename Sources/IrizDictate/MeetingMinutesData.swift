import Foundation

/// Данные согласованной формы: общая шапка и повторяемые карточки.
public struct MeetingMinutesData: Codable, Equatable, Sendable {
    public var fields: [String: String]
    public var blocks: [String: [[String: String]]]

    public init(fields: [String: String], blocks: [String: [[String: String]]]) {
        self.fields = fields
        self.blocks = blocks
    }

    private enum CodingKeys: String, CodingKey { case fields, blocks }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard Set(keys) == ["fields", "blocks"] else { throw MeetingTemplateError.invalidData }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fields = try values.decode([String: String].self, forKey: .fields)
        blocks = try values.decode([String: [[String: String]]].self, forKey: .blocks)
    }
}
