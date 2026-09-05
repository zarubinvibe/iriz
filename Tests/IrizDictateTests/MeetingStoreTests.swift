// Проба хранения встречи: звук и расшифровка обязаны лежать вместе.
//
// Это то самое место, где продукт нарушает собственное правило по решению
// владельца: в диктовке звук не хранится никогда, у встречи хранится. Проба
// судит, что правило исполняется целиком, а не наполовину - половина
// доказательства хуже его отсутствия, потому что создаёт видимость.
import Foundation
import Testing

@testable import IrizDictate

@Suite("Хранение встречи")
struct MeetingStoreTests {
    private func sandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iriz-meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fakeAudio(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("original.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        return url
    }

    @Test("сохраняются ОБА файла в одной папке")
    func сохраняютсяОбаФайла() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try fakeAudio(in: root)

        let saved = try MeetingStore.save(audio: audio, protocolText: "# Протокол\n",
                                          at: Date(timeIntervalSince1970: 1_757_000_000),
                                          title: "Заседание А65", in: root)

        #expect(FileManager.default.fileExists(atPath: saved.audio.path))
        #expect(FileManager.default.fileExists(atPath: saved.transcript.path))
        #expect(saved.audio.deletingLastPathComponent() == saved.transcript.deletingLastPathComponent())
    }

    @Test("оригинал владельца остаётся на месте")
    func оригиналОстаётсяНаМесте() throws {
        // Звук копируется, а не переносится: распоряжаться чужим оригиналом
        // приложение не имеет права.
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try fakeAudio(in: root)
        _ = try MeetingStore.save(audio: audio, protocolText: "x", title: "Встреча", in: root)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("права файлов закрыты")
    func праваЗакрыты() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try fakeAudio(in: root)
        let saved = try MeetingStore.save(audio: audio, protocolText: "x", title: "Встреча", in: root)
        for url in [saved.audio, saved.transcript] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            #expect(permissions == 0o600)
        }
    }

    @Test("папка встречи именуется временем и переживает кириллицу в названии")
    func папкаИменуетсяВременем() throws {
        // Кириллица в путях уже стоила этому дому отдельного разбора: название
        // целиком лежит внутри протокола, а имя папки остаётся латинским.
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try MeetingStore.meetingDirectory(
            at: Date(timeIntervalSince1970: 1_757_000_000),
            title: "Заседание по делу А65-1234/2026", in: root)
        let name = directory.lastPathComponent
        #expect(name.hasPrefix("2025-09-"))
        #expect(name.allSatisfy { $0.isASCII })
    }

    @Test("повторное сохранение не спотыкается о старый звук")
    func повторноеСохранение() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try fakeAudio(in: root)
        let date = Date(timeIntervalSince1970: 1_757_000_000)
        _ = try MeetingStore.save(audio: audio, protocolText: "первый", at: date,
                                  title: "Встреча", in: root)
        let second = try MeetingStore.save(audio: audio, protocolText: "второй", at: date,
                                           title: "Встреча", in: root)
        let text = try String(contentsOf: second.transcript, encoding: .utf8)
        #expect(text == "второй")
    }
}
