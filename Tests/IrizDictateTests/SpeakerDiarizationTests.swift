// Проба перевода отрезков движка в наш вид.
//
// Сам разбор записи требует моделей CoreML и минуты работы - под `swift test`
// ему не место. Судится то, что можно судить без движка: перевод типов,
// отсев мусора и порядок. Это единственное место, где чужой тип встречается с
// нашим, и ошибка здесь тихо перепутает, кто что сказал.
import Foundation
import Testing
import FluidAudio

@testable import IrizDictate

@Suite("Отрезки говорящих")
struct SpeakerDiarizationTests {
    @Test("офлайн-подготовка без кэша ничего не создаёт и не меняет сетевой флаг")
    func missingOfflineCacheIsReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iriz-diarizer-\(UUID())")
        let offlineBefore = DownloadUtils.enforceOffline
        let diarizer = SpeakerDiarizer(modelsDirectory: root)
        do {
            try await diarizer.prepareOffline()
            Issue.record("Отсутствующий кэш не должен загружаться")
        } catch let failure as SpeakerDiarizationFailure {
            #expect(failure == .modelsMissing)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(DownloadUtils.enforceOffline == offlineBefore)
        #expect(await diarizer.modelsInstalled == false)
    }

    @Test("отмена подготовки и разбора возвращает CancellationError до чтения файла")
    func cancelledOfflinePreparationDoesNotReadAudio() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let diarizer = SpeakerDiarizer(modelsDirectory: URL(fileURLWithPath: "/iriz-no-test-models"))
            do {
                try await diarizer.prepareOffline()
                Issue.record("Подготовка не должна продолжаться после отмены")
            } catch is CancellationError {} catch { Issue.record("Отмена подменена ошибкой модели") }
            do {
                _ = try await diarizer.spans(of: URL(fileURLWithPath: "/iriz-no-test-audio.wav"))
                Issue.record("Разбор не должен продолжаться после отмены")
            } catch is CancellationError {} catch { Issue.record("Отмена подменена ошибкой аудио") }
        }
        await task.value
    }

    @Test("удалённый URL отклоняется до AVFoundation и загрузки моделей")
    func remoteAudioURLIsRejected() async throws {
        let diarizer = SpeakerDiarizer(modelsDirectory: URL(fileURLWithPath: "/iriz-no-test-models"))
        do {
            _ = try await diarizer.spans(of: URL(string: "https://invalid.example/private-meeting.wav")!)
            Issue.record("Удалённый URL не разрешён")
        } catch let failure as SpeakerDiarizationFailure {
            #expect(failure == .audioUnreadable)
            #expect(!failure.rawValue.contains("private-meeting"))
        }
    }

    @Test("структурный probe сохраняет даже неполный кэш")
    func partialCacheIsNotDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iriz-diarizer-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(Repo.diarizer.folderName)
        let model = directory.appendingPathComponent("Segmentation.mlmodelc")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let sentinel = model.appendingPathComponent("coremldata.bin")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: sentinel)
        #expect(throws: SpeakerDiarizationFailure.modelsMissing) {
            try speakerDiarizationModelURLs(in: root)
        }
        #expect(try Data(contentsOf: sentinel) == bytes)
    }

    @Test("офлайн-layout требует четыре Core ML bundle и PLDA рядом")
    func completeOfflineLayoutUsesExpectedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iriz-diarizer-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(Repo.diarizer.folderName)
        #expect(Repo.diarizer.folderName == "speaker-diarization")
        let names = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc"]
        for name in names {
            let bundle = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data([1]).write(to: bundle.appendingPathComponent("coremldata.bin"))
        }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("plda-parameters.json"))
        let paths = try speakerDiarizationModelURLs(in: root)
        #expect(paths.map(\.lastPathComponent) == names + ["plda-parameters.json"])
        // Структурная проверка не пытается загрузить синтетические модели.
        #expect(paths.allSatisfy { $0.deletingLastPathComponent().path == directory.path })
    }

    @Test("PLDA читает Float32 little-endian и отвергает повреждённые данные")
    func validatesPLDAWithoutLoadingModels() throws {
        func json(_ bytes: Data) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tensors": ["psi": ["data_base64": bytes.base64EncodedString()]]])
        }
        #expect(try speakerDiarizationPLDAPsi(from: json(Data([0, 0, 128, 63, 0, 0, 0, 64]))) == [1, 2])
        for bytes in [Data(), Data([1, 2, 3]), Data([0, 0, 128, 127]), Data([0, 0, 128, 191])] {
            #expect(throws: SpeakerDiarizationFailure.modelsInvalid) {
                try speakerDiarizationPLDAPsi(from: json(bytes))
            }
        }
        for raw in ["{}", "not json", "{\"tensors\":{\"psi\":{\"data_base64\":\"%%%\"}}}"] {
            #expect(throws: SpeakerDiarizationFailure.modelsInvalid) {
                try speakerDiarizationPLDAPsi(from: Data(raw.utf8))
            }
        }
    }

    @Test("отрезки переводятся и сортируются по времени")
    func отрезкиПереводятсяИСортируются() {
        let spans = speakerSpans(from: [
            fakeSegment("S2", 5.0, 8.0),
            fakeSegment("S1", 0.0, 4.0),
        ])
        #expect(spans.map(\.speaker) == ["S1", "S2"])
        #expect(spans[0].start == 0.0)
        #expect(spans[1].end == 8.0)
    }

    @Test("пустой отрезок отбрасывается")
    func пустойОтрезокОтбрасывается() {
        // Отрезок нулевой длины не несёт речи, но ломает сшивку: слово может
        // перекрыться с ним на ноль и уйти не тому.
        let spans = speakerSpans(from: [fakeSegment("S1", 3.0, 3.0)])
        #expect(spans.isEmpty)
    }

    @Test("перевёрнутый отрезок отбрасывается")
    func перевёрнутыйОтрезокОтбрасывается() {
        let spans = speakerSpans(from: [fakeSegment("S1", 5.0, 2.0)])
        #expect(spans.isEmpty)
    }

    @Test("короткая запись до разбора не доходит")
    func короткаяЗаписьНеРазбирается() {
        // Отказ по имени, а не молчание: разбирать будут запись заседания, и
        // «не смог» без причины неотличимо от поломки.
        #expect(SpeakerDiarizationFailure.tooShort.rawValue.contains("короче"))
        #expect(speakerDiarizationMinimumSeconds == 3)
    }

    private func fakeSegment(_ id: String, _ start: Float, _ end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(speakerId: id, embedding: [], startTimeSeconds: start,
                            endTimeSeconds: end, qualityScore: 1)
    }
}
