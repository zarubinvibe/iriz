// Тесты политики глушения движка после диктовки (Д2).
// Железо (микрофон) под тест-раннером недоступно — TCC не выдаёт grant
// ad-hoc бинарю `swift test`, поэтому решение политики наблюдается через
// policyStopRequestCount (DEBUG-опора) и idleStopPending, а не живой движок.
import Foundation
import Testing

@testable import IrizDictate

@Suite("EngineShutdownPolicy")
struct EngineShutdownTests {

    @Test func immediateStopsEngineRightAfterEndRecording() {
        let capture = AudioCapture(shutdownPolicy: .immediate)
        _ = capture.endRecording()
        #expect(capture.policyStopRequestCount == 1)
        #expect(capture.idleStopPending == false)
        #expect(capture.isEngineStarted == false)
    }

    @Test func keepWarmLeavesEngineAloneAfterEndRecording() {
        let capture = AudioCapture(shutdownPolicy: .keepWarm)
        _ = capture.endRecording()
        #expect(capture.policyStopRequestCount == 0)
        #expect(capture.idleStopPending == false)
    }

    @Test func idleTimeoutSchedulesStopAfterEndRecording() {
        let capture = AudioCapture(shutdownPolicy: .idleTimeout, idleTimeout: 60)
        _ = capture.endRecording()
        #expect(capture.idleStopPending == true)
        #expect(capture.policyStopRequestCount == 0)
    }

    @Test func beginRecordingCancelsPendingIdleStop() {
        let capture = AudioCapture(shutdownPolicy: .idleTimeout, idleTimeout: 60)
        _ = capture.endRecording()
        #expect(capture.idleStopPending == true)

        capture.beginRecording()
        #expect(capture.idleStopPending == false)
        #expect(capture.policyStopRequestCount == 0)
        #expect(capture.isRunning == true)
    }

    @Test func idleTimeoutFiresAndStopsEngine() async throws {
        let capture = AudioCapture(shutdownPolicy: .idleTimeout, idleTimeout: 0.05)
        _ = capture.endRecording()
        #expect(capture.idleStopPending == true)

        let deadline = ContinuousClock.now + .seconds(2)
        while capture.policyStopRequestCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(capture.policyStopRequestCount == 1)
        #expect(capture.idleStopPending == false)
        #expect(capture.isEngineStarted == false)
    }

    @Test func repeatedEndRecordingKeepsSinglePendingIdleStop() {
        let capture = AudioCapture(shutdownPolicy: .idleTimeout, idleTimeout: 60)
        _ = capture.endRecording()
        _ = capture.endRecording()
        #expect(capture.idleStopPending == true)
        capture.beginRecording()
        #expect(capture.idleStopPending == false)
        #expect(capture.policyStopRequestCount == 0)
    }
}
