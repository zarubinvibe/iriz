import Combine
import Darwin
import Foundation
import IrizCore
import IrizDictate

/// Очередь переживает смену страницы; повтор запускает только оставшиеся файлы.
@MainActor
final class SettingsFileTranscription: ObservableObject {
    typealias Progress = @Sendable (String, Double?) async -> Void
    typealias ProcessFile = @Sendable (AudioTranscriptionJob, AudioFileTranscriber,
                                      DictationLanguage, @escaping Progress) async throws -> Void

    @Published var queue: [IrizDropItem] = []
    @Published private(set) var busy = false
    @Published private(set) var stopping = false
    @Published private(set) var progress: String?
    @Published private(set) var fraction: Double?
    @Published private(set) var report: String?
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var results: [AudioTranscriptionJob] = []
    private let processFile: ProcessFile

    init(processFile: @escaping ProcessFile = SettingsFileTranscription.process) {
        self.processFile = processFile
    }

    @discardableResult
    func start(engine: SpeechModelProfile, language: DictationLanguage) -> Task<Void, Never>? {
        guard !busy, !queue.isEmpty else { return nil }
        // До Task: второе нажатие в том же проходе run loop уже не запустит модель.
        busy = true
        stopping = false
        report = nil
        errors = [:]
        let items = queue
        let transcriber = AudioFileTranscriber(engine: engine)
        return Task {
            var done = 0
            defer {
                busy = false
                progress = nil
                fraction = nil
                report = Lf("files.finished", "Готово: %d из %d.", done, items.count)
                    + (stopping ? " " + L("files.stopped", "Очередь остановлена. Оставшиеся файлы можно запустить снова.") : "")
            }
            for (index, item) in items.enumerated() {
                guard !stopping else { break }
                let name = item.url.lastPathComponent
                progress = "[\(index + 1)/\(items.count)] \(name)"
                fraction = nil
                do {
                    let jobs = try await Task.detached(priority: .userInitiated) {
                        try AudioFileBatch.plan(inputPath: item.url.path, force: false)
                    }.value
                    guard let job = jobs.first, jobs.count == 1 else {
                        throw AudioBatchPlanError.pathNotReadable(item.url.path)
                    }
                    try await processFile(job, transcriber, language) { step, value in
                        await MainActor.run {
                            self.progress = "[\(index + 1)/\(items.count)] \(name): \(step)"
                            self.fraction = value
                        }
                    }
                    results.removeAll { $0.source == job.source }
                    results.append(job)
                    queue.removeAll { $0.id == item.id }
                    done += 1
                } catch {
                    errors[item.id] = Self.message(for: error)
                }
            }
        }
    }

    /// У распознавателя нет безопасного мгновенного прерывания. Текущий результат
    /// сохраняется, следующий файл не начинается; это прямо написано на кнопке.
    func stopAfterCurrent() { if busy { stopping = true } }

    nonisolated private static func process(_ job: AudioTranscriptionJob,
                                           transcriber: AudioFileTranscriber,
                                           language: DictationLanguage,
                                           progress: @escaping Progress) async throws {
        await progress(L("files.preparing", "загружаю модель"), nil)
        _ = try await transcriber.prepare()
        await progress(L("files.reading", "читаю запись"), nil)
        let audio = try await AudioFileDecoder.decode(job.source)
        await progress(L("files.transcribing", "расшифровываю"), nil)
        var reporter: Task<Void, Never>?
        if AudioFileTranscriber.reportsProgress(forSamples: audio.samples.count),
           let stream = await transcriber.progressStream() {
            reporter = Task {
                do {
                    for try await value in stream {
                        guard !Task.isCancelled else { break }
                        await progress(L("files.transcribing", "расшифровываю"), min(1, max(0, value)))
                    }
                } catch { /* Текстовая стадия остаётся видимой, если поток прогресса закрыт. */ }
            }
        }
        defer { reporter?.cancel() }
        let transcript = try await transcriber.transcribe(audio, language: language)
        reporter?.cancel()
        await reporter?.value
        await progress(L("files.saving", "сохраняю текст"), nil)
        try saveTranscript(transcript.text, to: job.destination)
    }

    /// Готовый текст появляется целиком, с правами 0600. link отказывает при
    /// существующем имени даже тогда, когда файл появился уже после plan().
    nonisolated static func saveTranscript(_ text: String, to destination: URL) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw NSError(domain: "IrizFileTranscription", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("files.noSpeech", "Речь не распознана. Текстовый файл не создан.")])
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".iriz-transcript-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                     PRIVATE_LOG_FILE_MODE)
        guard descriptor >= 0 else { throw IrizCore.currentPOSIXError() }
        defer {
            _ = Darwin.close(descriptor)
            _ = Darwin.unlink(temporary.path)
        }
        try IrizCore.writeAllData(Data((text + "\n").utf8), to: descriptor)
        guard Darwin.link(temporary.path, destination.path) == 0 else {
            if errno == EEXIST { throw AudioBatchPlanError.destinationExists(destination.path) }
            throw IrizCore.currentPOSIXError()
        }
    }

    nonisolated static func message(for error: Error) -> String {
        if case AudioBatchPlanError.destinationExists(let path) = error {
            return Lf("files.destinationExists", "Текст уже есть: %@. Открой его или переименуй исходную запись перед повтором.", path)
        }
        return (error as? AudioBatchPlanError)?.message
            ?? (error as? AudioDecodingError)?.message
            ?? error.localizedDescription
    }
}
