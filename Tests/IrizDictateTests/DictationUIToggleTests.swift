import Foundation
import IrizCore
import Testing

@testable import IrizDictate

@MainActor
@Suite("Кнопка записи в знакомстве и HUD")
struct DictationUIToggleTests {
    private func makeController() -> (DictationController, () -> Void) {
        let name = "iriz-ui-toggle-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let settings = DictationSettings(defaults: defaults)
        settings.playFeedbackSounds = false
        let controller = DictationController(settings: settings,
                                            insertionStats: InsertionStats(defaults: defaults))
        return (controller, { removeSuiteFile(named: name, defaults: defaults) })
    }

    @Test("повторное нажатие завершает запись вместо отказа alreadyRecording")
    func secondClickFinishesRecording() {
        let (controller, cleanup) = makeController()
        defer { cleanup() }
        // Только пустой буфер: опора не включает микрофон и не запускает ASR.
        controller.simulateActiveRecordingForTesting()
        #expect(controller.isRecordingActive)
        controller.toggleDictationFromUI()
        #expect(!controller.isRecordingActive)
        #expect(!controller.audioStateForTesting.isRunning)
        #expect(controller.state == .ready)
    }

    @Test("нажатие во время разбора не запускает и не отменяет запись")
    func busyProcessingIsPreserved() {
        let (controller, cleanup) = makeController()
        defer { cleanup() }
        #expect(controller.beginMeetingProcessing() != nil)
        controller.toggleDictationFromUI()
        #expect(controller.isBusyForTesting)
        #expect(controller.state == .transcribing)
        #expect(!controller.isRecordingActive)
        controller.stop()
    }
}
