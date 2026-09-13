import Foundation
import Testing
@testable import IrizDictate

@Suite("Архив шаблонных протоколов", .serialized)
struct MeetingArchiveTests {
    private func fixture() throws -> (URL, URL, MeetingSource) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iriz-meeting-archive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let audio = root.appendingPathComponent("fixture.wav")
        try Data("synthetic audio fixture; not a real recording".utf8).write(to: audio)
        let transcript = AudioFileTranscript(text: " Да, да.\nНе законченная…  ", processingSeconds: 1,
                                              audioSeconds: 8, tokenTimings: [])
        let source = MeetingSource(title: "Синтетическая встреча", importedAt: Date(timeIntervalSince1970: 100),
                                   recordedAt: nil, audioSeconds: 8,
                                   transcript: meetingTranscriptSnapshot(transcript: transcript, spans: []))
        return (root, audio, source)
    }

    @Test("исходник неизменен, форма и заполненная версия сохраняются отдельно")
    func versionedExport() throws {
        let (root, audio, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: audio)
        let base = try MeetingStore.save(audio: audio, protocolText: source.transcript.rawText,
                                        title: source.title, in: root, source: source)
        let restored = try MeetingStore.loadSource(for: base)
        #expect(restored == source)
        let data = try MeetingMinutesGenerator.baseData(for: restored)
        let blank = try MeetingStore.exportMinutes(data, for: base, filled: false)
        let firstDOCX = try Data(contentsOf: #require(blank.minutes))
        // Содержательные fake-данные проверяются в generator suite; здесь
        // проверяется только атомарная смена версии, не качество протокола.
        let filled = try MeetingStore.exportMinutes(data, for: blank, filled: true)
        #expect(filled.minutesFilled)
        #expect(blank.minutes != filled.minutes)
        #expect(try Data(contentsOf: #require(blank.minutes)) == firstDOCX)
        #expect(try Data(contentsOf: audio) == original)
        #expect(try Data(contentsOf: base.audio) == original)
        #expect(try MeetingStore.loadSource(for: filled) == source)
        #expect(try MeetingStore.recent(in: root).first?.minutes?.standardizedFileURL == filled.minutes?.standardizedFileURL)
        for url in [filled.source, filled.minutes, filled.data, filled.clarifications].compactMap({ $0 }) {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
        #expect(try String(contentsOf: #require(filled.clarifications), encoding: .utf8).contains("Не согласован"))
    }

    @Test("ошибка новой версии не удаляет аудио и предыдущий DOCX")
    func failedExportPreservesEvidence() throws {
        let (root, audio, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try MeetingStore.save(audio: audio, protocolText: source.transcript.rawText,
                                        title: source.title, in: root, source: source)
        var data = try MeetingMinutesGenerator.baseData(for: source)
        let old = try MeetingStore.exportMinutes(data, for: base, filled: false)
        let before = try Data(contentsOf: #require(old.minutes))
        data.fields.removeValue(forKey: "approval_status")
        #expect(throws: (any Error).self) { try MeetingStore.exportMinutes(data, for: old, filled: true) }
        #expect(try Data(contentsOf: #require(old.minutes)) == before)
        #expect(try MeetingStore.loadSource(for: old) == source)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.directory.path)
        #expect(!names.contains { $0.hasPrefix(".export-") })
        #expect(try MeetingStore.recent(in: root).first?.minutesFilled == false)
    }

    @Test("старый архив остаётся доступным без притворного DOCX")
    func legacyArchive() throws {
        let (root, audio, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try MeetingStore.save(audio: audio, protocolText: "старый Markdown", title: source.title, in: root)
        let saved = try #require(MeetingStore.recent(in: root).first)
        #expect(saved.source == nil && saved.minutes == nil && saved.data == nil)
        #expect(!saved.minutesFilled)
        #expect(throws: MeetingArchiveError.self) { try MeetingStore.loadSource(for: saved) }
    }

    @Test("повтор отказывается читать подменённый symlink-источник")
    func sourceSymlinkRefused() throws {
        let (root, audio, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try MeetingStore.save(audio: audio, protocolText: "fixture", title: source.title, in: root, source: source)
        let sourceURL = try #require(base.source)
        let backup = root.appendingPathComponent("own-source-backup.json")
        try FileManager.default.moveItem(at: sourceURL, to: backup)
        try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: backup)
        #expect(throws: MeetingArchiveError.self) { try MeetingStore.loadSource(for: base) }
        #expect(try MeetingStore.recent(in: root).first?.source == nil)
    }

    @Test("аудио по symlink копируется байтами без изменения прав оригинала")
    func audioSymlinkCopiesContents() throws {
        let (root, audio, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: audio.path)
        let link = root.appendingPathComponent("selected.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: audio)
        let base = try MeetingStore.save(audio: link, protocolText: "fixture", title: source.title, in: root, source: source)
        #expect(try base.audio.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try Data(contentsOf: base.audio) == Data(contentsOf: audio))
        let attributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test("две версии за одну секунду сортируются по точному времени")
    func subsecondExportOrder() throws {
        let (root, audio, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try MeetingStore.save(audio: audio, protocolText: "fixture", title: source.title, in: root, source: source)
        let data = try MeetingMinutesGenerator.baseData(for: source)
        let first = try MeetingStore.exportMinutes(data, for: base, filled: false)
        let second = try MeetingStore.exportMinutes(data, for: first, filled: true)
        for (value, time) in [(first, 100.1), (second, 100.9)] {
            let receipt = try #require(value.minutes).deletingLastPathComponent().appendingPathComponent("export.json")
            let json = try JSONSerialization.data(withJSONObject: ["createdAt": time, "filled": value.minutesFilled])
            try json.write(to: receipt)
        }
        #expect(try MeetingStore.recent(in: root).first?.minutes?.standardizedFileURL == second.minutes?.standardizedFileURL)
        #expect(try MeetingStore.recent(in: root).first?.minutesFilled == true)
    }

    @Test("отменённый экспорт не публикует новую версию")
    func cancelledExportDoesNotCommit() async throws {
        let (root, audio, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try MeetingStore.save(audio: audio, protocolText: "fixture", title: source.title, in: root, source: source)
        let data = try MeetingMinutesGenerator.baseData(for: source)
        let old = try MeetingStore.exportMinutes(data, for: base, filled: false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MeetingStore.exportMinutes(data, for: old, filled: true)
        }
        do {
            _ = try await task.value
            Issue.record("Отменённый экспорт опубликовал результат")
        } catch is CancellationError {} catch {
            Issue.record("Отмена подменена другим отказом")
        }
        #expect(try MeetingStore.recent(in: root).first?.minutes?.standardizedFileURL == old.minutes?.standardizedFileURL)
        #expect(try MeetingStore.recent(in: root).first?.minutesFilled == false)
        #expect(try MeetingStore.loadSource(for: old) == source)
    }
}
