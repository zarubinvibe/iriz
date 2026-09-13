import Foundation
import Testing

/// Read-only ворота подключения private SwiftUI-состояния. Это не UI/E2E-прогон:
/// окна, разрешения, распознаватель и настоящий агент здесь не запускаются.
@Suite("Подключение отмены заполнения встречи")
struct SettingsMeetingCancellationTests {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/IrizSettings/IrizSettingsView.swift"),
                          encoding: .utf8)
    }

    private func fragment(_ source: String, after start: String, before end: String) throws -> String {
        let lower = try #require(source.range(of: start)?.upperBound)
        let upper = try #require(source.range(of: end, range: lower..<source.endIndex)?.lowerBound)
        return String(source[lower..<upper])
    }

    private func retry() throws -> String {
        try fragment(source(), after: "private func fillMeetingMinutes(", before: "private func openFileResult(")
    }

    @Test("задача отдельного заполнения хранится и освобождается после завершения")
    func retryOwnsItsCancellableTask() throws {
        #expect(try source().contains("@State private var meetingFillTask: Task<Void, Never>?"))
        let code = try retry()
        #expect(code.contains("meetingFillTask = Task { @MainActor in"))
        let cleanup = try fragment(code, after: "defer {", before: "do {")
        #expect(cleanup.contains("meetingFillTask = nil"))
        #expect(cleanup.contains("meetingFillCancelling = false"))
        #expect(cleanup.contains("meetingBusy = false"))
    }

    @Test("кнопка и Escape отменяют задачу и отключают повторное нажатие")
    func buttonCancelsTaskAndIgnoresLateProgress() throws {
        let code = try fragment(source(), after: "if let meetingProgress", before: "if let meetingReport")
        #expect(code.contains("else if meetingFillTask != nil"))
        #expect(code.contains("meetingFillTask?.cancel()"))
        #expect(code.contains("meetingFillCancelling = true"))
        #expect(code.contains("meetingProgressID = nil"))
        #expect(code.contains(".disabled(meetingFillCancelling)"))
        #expect(code.contains(".keyboardShortcut(.cancelAction)"))
    }

    @Test("отмена имеет отдельный исход без ошибки, автоповтора и замены файлов")
    func cancellationIsNotFailureOrAutomaticRetry() throws {
        let code = try fragment(retry(), after: "catch is CancellationError {", before: "} catch {")
        #expect(code.contains("meetingFailed = false"))
        #expect(code.contains("meetings.fillCancelled"))
        #expect(!code.contains("fillMinutes("))
        #expect(!code.contains("rememberMeeting("))
        #expect(!code.contains("meetingQueue."))
    }

    @Test("повтор не запускает ASR и показывает подтверждённое сохранение даже при поздней отмене")
    func retryUsesSavedSourceAndShowsCommittedResult() throws {
        let code = try retry()
        #expect(code.contains("MeetingPipeline().fillMinutes(for: artifacts"))
        #expect(!code.contains(".run("))
        #expect(!code.contains(".prepare("))
        #expect(!code.contains("AudioFileTranscriber("))
        let committed = try fragment(code, after: "let completed = try await", before: "catch is CancellationError")
        #expect(committed.contains("rememberMeeting(completed)"))
        #expect(committed.contains("meetingReport = meetingResultStatus(completed)"))
        #expect(!committed.contains("Task.checkCancellation()"))
        #expect(!committed.contains("Task.isCancelled"))
    }
}
