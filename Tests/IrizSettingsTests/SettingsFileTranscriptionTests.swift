import Foundation
import IrizDictate
import Testing
@testable import IrizSettings

@MainActor
@Suite("File transcription UI: safe queue and output")
struct SettingsFileTranscriptionTests {
    @Test func preservesExistingTextAndWritesOnlyCompletePrivateResults() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.txt")
        try Data("owner text".utf8).write(to: existing)
        #expect(throws: AudioBatchPlanError.destinationExists(existing.path)) {
            try SettingsFileTranscription.saveTranscript("new text", to: existing)
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "owner text")

        let output = root.appendingPathComponent("result.txt")
        #expect(throws: (any Error).self) {
            try SettingsFileTranscription.saveTranscript(" \n ", to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try SettingsFileTranscription.saveTranscript("  Complete text.\n", to: output)
        #expect(try String(contentsOf: output, encoding: .utf8) == "Complete text.\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".iriz-transcript-") })
    }

    @Test func preventsDoubleSubmitAndRetriesOnlyFailedFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try source("first.wav", in: root)
        let second = try source("second.wav", in: root)
        let attempts = Attempts()
        let model = SettingsFileTranscription { job, _, language, progress in
            let fail = await attempts.record(job.source, language: language)
            await progress("test", 0.5)
            if fail { throw CocoaError(.fileReadCorruptFile) }
            try SettingsFileTranscription.saveTranscript("test transcript", to: job.destination)
        }
        model.queue = [first, second]
        let task = model.start(engine: .whisperLargeV3, language: .english)
        #expect(model.busy)
        #expect(model.start(engine: .multilingualV3, language: .russian) == nil)
        await task?.value
        #expect(!model.busy)
        #expect(model.queue == [second])
        #expect(model.results.map(\.source) == [first.url])
        #expect(model.errors[second.id] != nil)
        #expect(model.progress == nil)
        #expect(model.fraction == nil)

        await model.start(engine: .whisperLargeV3, language: .english)?.value
        #expect(model.queue.isEmpty)
        #expect(model.errors.isEmpty)
        #expect(model.results.map(\.source) == [first.url, second.url])
        #expect(await attempts.sources == [first.url, second.url, second.url])
        #expect(await attempts.languages == [.english, .english, .english])
    }

    @Test func stopFinishesCurrentFileAndKeepsRemainingQueue() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try source("first.wav", in: root)
        let second = try source("second.wav", in: root)
        let started = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let model = SettingsFileTranscription { job, _, _, _ in
            started.continuation.yield(())
            for await _ in resume.stream { break }
            try SettingsFileTranscription.saveTranscript("finished", to: job.destination)
        }
        model.queue = [first, second]
        let task = model.start(engine: .multilingualV3, language: .auto)
        for await _ in started.stream { break }
        model.stopAfterCurrent()
        resume.continuation.yield(())
        await task?.value
        started.continuation.finish()
        resume.continuation.finish()
        #expect(model.queue == [second])
        #expect(model.results.map(\.source) == [first.url])
        #expect(model.stopping)
        #expect(!model.busy)
    }

    @Test func rejectsRemoteURLsBeforeAVFoundation() {
        #expect(!irizDropAccepts(URL(string: "https://example.com/voice.wav")!, extensions: ["wav"]))
        #expect(irizDropAccepts(URL(fileURLWithPath: "/tmp/voice.WAV"), extensions: ["wav"]))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iriz-file-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func source(_ name: String, in root: URL) throws -> IrizDropItem {
        let url = root.appendingPathComponent(name)
        // Только имена и очередь: ASR и декодер тесты не вызывают.
        try Data("fixture".utf8).write(to: url)
        return IrizDropItem(url: url, bytes: 7)
    }
}

private actor Attempts {
    var sources: [URL] = []
    var languages: [DictationLanguage] = []
    func record(_ source: URL, language: DictationLanguage) -> Bool {
        sources.append(source)
        languages.append(language)
        return source.lastPathComponent == "second.wav" && sources.filter { $0 == source }.count == 1
    }
}
