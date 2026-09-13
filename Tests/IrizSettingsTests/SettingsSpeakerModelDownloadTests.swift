import Foundation
import Testing

/// Проверяем wiring чтением исходника: не открываем UI, не читаем пользовательский
/// кэш, не запускаем сеть, установщик или ML-модели. Это не UI/E2E-прогон.
@Suite("Явная загрузка моделей голосов: подключение")
struct SettingsSpeakerModelDownloadTests {
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

    private func installer() throws -> String {
        try fragment(source(), after: "private func startSpeakerModelDownload()", before: "private func meetingResultRow(")
    }

    @Test("открытие раздела только проверяет установку, не запускает скачивание")
    func openingOnlyProbesTheCache() throws {
        let code = try source()
        let controls = try fragment(code, after: "private var speakerModelControls:", before: "private func refreshSpeakerModelStatus()")
        let probe = try fragment(code, after: "private func refreshSpeakerModelStatus()", before: "private func startSpeakerModelDownload()")
        #expect(controls.contains(".task { await refreshSpeakerModelStatus() }"))
        #expect(probe.contains("SpeakerModelInstaller.shared.isInstalled()"))
        #expect(probe.contains("!isPreview"))
        #expect(!probe.contains(".install"))
        #expect(!probe.contains("startSpeakerModelDownload()"))
    }

    @Test("единственный запуск установщика идёт от явной кнопки с ценой и источником")
    func downloadHasAnExplicitButtonAndDisclosure() throws {
        let code = try source()
        let controls = try fragment(code, after: "private var speakerModelControls:", before: "private func refreshSpeakerModelStatus()")
        #expect(controls.contains("Button(speakerModelFailed"))
        #expect(controls.contains("startSpeakerModelDownload()"))
        #expect(controls.contains("speakerModelDownloadBytes"))
        #expect(controls.contains("Hugging Face"))
        #expect(controls.contains("meetings.speakerModels.downloadHint"))
        #expect(code.components(separatedBy: "SpeakerModelInstaller.shared.install").count == 2)
        #expect(try installer().contains("try await SpeakerModelInstaller.shared.install"))
    }

    @Test("установка и обработка файлов взаимно блокируют повторные запуски")
    func installationSharesTheLocalBusyGuards() throws {
        let install = try installer()
        #expect(install.contains("!speakerModelInstalling"))
        #expect(install.contains("!speakerModelChecking"))
        #expect(install.contains("!meetingBusy, !files.busy"))
        let code = try source()
        let meetings = try fragment(code, after: "private func runMeetings()", before: "private func fillMeetingMinutes(")
        let files = try fragment(code, after: "private var filesSection:", before: "private var historySection:")
        #expect(meetings.contains("!speakerModelInstalling"))
        #expect(files.contains("guard !meetingBusy, !speakerModelInstalling"))
    }

    @Test("отсутствие моделей голосов не блокирует ASR встречи")
    func missingSpeakerModelsAreNotAnASRGate() throws {
        let code = try source()
        let meetings = try fragment(code, after: "private func runMeetings()", before: "private func fillMeetingMinutes(")
        #expect(!meetings.contains("speakerModelsInstalled"))
        #expect(code.contains("meetings.speakerModels.optional"))
        #expect(meetings.contains("pipeline.run("))
    }

    @Test("загрузка имеет отменяемую задачу, безопасный прогресс и отдельный исход отмены")
    func cancellationAndProgressAreWired() throws {
        let code = try source()
        let controls = try fragment(code, after: "private var speakerModelControls:", before: "private func refreshSpeakerModelStatus()")
        let install = try installer()
        #expect(controls.contains("speakerModelTask?.cancel()"))
        #expect(controls.contains("speakerModelProgressID = nil"))
        #expect(controls.contains(".disabled(speakerModelCancelling)"))
        #expect(controls.contains(".keyboardShortcut(.cancelAction)"))
        #expect(install.contains("speakerModelTask = Task { @MainActor in"))
        #expect(install.contains("speakerModelTask = nil"))
        #expect(install.contains("fraction.isFinite"))
        #expect(install.contains("speakerModelFraction = min(1, max(0, fraction))"))
        let cancelled = try fragment(install, after: "catch is CancellationError {", before: "} catch {")
        #expect(cancelled.contains("speakerModelFailed = false"))
        #expect(!cancelled.contains(".install"))
        #expect(!cancelled.contains("startSpeakerModelDownload()"))
    }
}
