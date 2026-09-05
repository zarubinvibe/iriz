import Foundation
import IrizCore
import Testing

@testable import IrizDictate

private enum SyntheticAudioStartError: Error, Equatable {
    case first
    case second
}

@Suite("audio engine start retry")
struct AudioEngineStartRetryTests {
    @Test func retriesOnceAfterFailure() throws {
        var attempts = 0
        var delays: [TimeInterval] = []

        try AudioEngineStartRetry.run(sleep: { delays.append($0) }) {
            attempts += 1
            if attempts == 1 { throw SyntheticAudioStartError.first }
        }

        #expect(attempts == 2)
        #expect(delays == [AudioEngineStartRetry.backoffSeconds])
    }

    @Test func stopsAfterSecondFailureAndThrowsLatestError() {
        var attempts = 0
        var delays: [TimeInterval] = []
        var caught: SyntheticAudioStartError?

        do {
            try AudioEngineStartRetry.run(sleep: { delays.append($0) }) {
                attempts += 1
                throw attempts == 1
                    ? SyntheticAudioStartError.first
                    : SyntheticAudioStartError.second
            }
        } catch {
            caught = error as? SyntheticAudioStartError
        }

        #expect(caught == .second)
        #expect(attempts == AudioEngineStartRetry.maximumAttempts)
        #expect(delays == [AudioEngineStartRetry.backoffSeconds])
    }

    @Test func successfulStartDoesNotSleepOrRetry() throws {
        var attempts = 0
        var delays: [TimeInterval] = []

        try AudioEngineStartRetry.run(sleep: { delays.append($0) }) {
            attempts += 1
        }

        #expect(attempts == 1)
        #expect(delays.isEmpty)
    }
}

@Suite("audio power lifecycle")
struct AudioPowerLifecycleTests {
    @Test func repeatedNotificationsAreIdempotent() {
        var lifecycle = AudioPowerLifecycle()

        #expect(lifecycle.transition(for: .willSleep) == .suspendRuntime)
        #expect(lifecycle.transition(for: .willSleep) == .none)
        #expect(lifecycle.transition(for: .didWake) == .resumeListening)
        #expect(lifecycle.transition(for: .didWake) == .none)
    }

    @Test func wakeWithoutPriorSleepDoesNothing() {
        var lifecycle = AudioPowerLifecycle()

        #expect(lifecycle.transition(for: .didWake) == .none)
        #expect(lifecycle.isSuspended == false)
    }
}

@Suite("audio graph recovery failure")
struct AudioGraphRecoveryFailureTests {
    @Test func failedRecoveryStopsAcceptingSamples() {
        let capture = AudioCapture(shutdownPolicy: .keepWarm)
        capture.beginRecording()
        #expect(capture.isRunning)

        capture.failClosedAfterConfigurationRecoveryFailure()

        #expect(capture.isRunning == false)
        #expect(capture.isEngineStarted == false)
        #expect(capture.latestRecordingLevelSnapshot().level == 0)
    }
}

@Suite("controller sleep recovery")
@MainActor
struct DictationSleepRecoveryTests {
    private func makeController() -> (DictationController, () -> Void) {
        let name = "smltlk-audio-sleep-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let controller = DictationController(
            settings: DictationSettings(defaults: defaults),
            insertionStats: InsertionStats(defaults: defaults)
        )
        return (controller, { removeSuiteFile(named: name, defaults: defaults) })
    }

    @Test func sleepCancelsActiveRecordingAndStopsAudio() {
        let (controller, cleanup) = makeController()
        defer { cleanup() }
        controller.simulateActiveRecordingForTesting()
        #expect(controller.isRecordingActive)
        #expect(controller.audioStateForTesting.isRunning)

        controller.prepareForSystemSleep()

        #expect(controller.isRecordingActive == false)
        #expect(controller.audioStateForTesting.isRunning == false)
        #expect(controller.audioStateForTesting.isEngineStarted == false)
        #expect(controller.state == .warmingUp)
        #expect(controller.isSuspendedForSystemSleepForTesting)
    }

    @Test func repeatedSleepIsHarmless() {
        let (controller, cleanup) = makeController()
        defer { cleanup() }

        controller.prepareForSystemSleep()
        controller.prepareForSystemSleep()

        #expect(controller.isRecordingActive == false)
        #expect(controller.audioStateForTesting.isRunning == false)
        #expect(controller.isSuspendedForSystemSleepForTesting)
    }
}
