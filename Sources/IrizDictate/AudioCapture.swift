// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4.
// Захват звука: тап на inputNode AVAudioEngine, ручной моно-микс по
// RMS-активным каналам, AVAudioConverter → 16 кГц Float32 mono.
// Отличие от донора: журнал восстановления после падения (PendingDictationJournal)
// в срез не вошёл — параметры recoveryJournal удалены.
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

private let CORE_AUDIO_DEFAULT_AGGREGATE_PREFIX = "CADefaultDeviceAggregate-"

// MARK: - Аудиоустройства ввода (CoreAudio HAL)

func audioObjectStringProperty(_ objectID: AudioObjectID,
                               selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var rawValue: UnsafeRawPointer?
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &rawValue)
    guard status == noErr, let rawValue else { return nil }
    let string = Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
    return string.isEmpty ? nil : string
}

func audioDeviceHasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                             mScope: kAudioDevicePropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
          size > 0 else { return false }

    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
        return false
    }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffers.contains { $0.mNumberChannels > 0 }
}

func isDefaultAggregateAudioInputPreference(_ preference: String) -> Bool {
    let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.range(of: CORE_AUDIO_DEFAULT_AGGREGATE_PREFIX,
                         options: [.anchored, .caseInsensitive]) != nil
}

func normalizedInputDevicePreference(_ preference: String) -> String? {
    let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.utf8.count <= MAX_INPUT_DEVICE_PREFERENCE_BYTES,
          !trimmed.unicodeScalars.contains(where: { $0.value == 0 }),
          !isDefaultAggregateAudioInputPreference(trimmed) else {
        return nil
    }
    return trimmed
}

func isDefaultAggregateAudioInputDevice(_ device: AudioInputDevice) -> Bool {
    isDefaultAggregateAudioInputPreference(device.uid)
        || isDefaultAggregateAudioInputPreference(device.name)
}

func availableAudioInputDevices() -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = Array(repeating: AudioDeviceID(0), count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &address, 0, nil, &size, &ids) == noErr else { return [] }

    return ids.compactMap { id in
        guard audioDeviceHasInputChannels(id),
              let uid = audioObjectStringProperty(id, selector: kAudioDevicePropertyDeviceUID),
              let name = audioObjectStringProperty(id, selector: kAudioObjectPropertyName) else {
            return nil
        }
        let device = AudioInputDevice(id: id, uid: uid, name: name)
        return isDefaultAggregateAudioInputDevice(device) ? nil : device
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

func audioInputDevice(matching preference: String,
                      in devices: [AudioInputDevice] = availableAudioInputDevices()) -> AudioInputDevice? {
    guard let trimmed = normalizedInputDevicePreference(preference) else { return nil }
    return devices.first { $0.uid == trimmed }
        ?? devices.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
}

func currentAudioInputDeviceID(for unit: AudioUnit) -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioUnitGetProperty(unit,
                                      kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global,
                                      0,
                                      &deviceID,
                                      &size)
    guard status == noErr, size == UInt32(MemoryLayout<AudioDeviceID>.size) else {
        return nil
    }
    return deviceID
}

func audioInputDeviceNominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var sampleRate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(deviceID,
                                            &address,
                                            0,
                                            nil,
                                            &size,
                                            &sampleRate)
    guard status == noErr, sampleRate > 0 else { return nil }
    return sampleRate
}

// MARK: - Захваченная запись

struct CapturedAudioSegments {
    let segments: [[Float]]
    let sampleCount: Int

    func flattened() -> [Float] {
        guard sampleCount > 0 else { return [] }
        var out: [Float] = []
        out.reserveCapacity(sampleCount)
        for segment in segments {
            out.append(contentsOf: segment)
        }
        return out
    }
}

struct CapturedRecording {
    let samples: [Float]
    let detachSeconds: TimeInterval
    let flattenSeconds: TimeInterval
}

// MARK: - Микширование в моно

struct AudioSampleAccumulator {
    private var segments: [[Float]] = []
    private(set) var sampleCount = 0

    mutating func append(_ segment: [Float]) {
        guard !segment.isEmpty else { return }
        segments.append(segment)
        sampleCount += segment.count
    }

    mutating func removeAll(keepingCapacity: Bool) {
        segments.removeAll(keepingCapacity: keepingCapacity)
        sampleCount = 0
    }

    mutating func drain() -> CapturedAudioSegments {
        let captured = CapturedAudioSegments(segments: segments,
                                             sampleCount: sampleCount)
        segments.removeAll(keepingCapacity: true)
        sampleCount = 0
        return captured
    }
}

func selectedMonoMixChannelIndices(channelRMS: [Double]) -> [Int] {
    let peak = channelRMS.max() ?? 0
    let active = channelRMS.enumerated()
        .filter { pair in peak > 0 && pair.element >= peak * 0.25 }
        .map { $0.offset }
    return active.isEmpty ? [0] : active
}

func channelRMSValues(channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                      channelCount: Int,
                      frameCount: Int) -> [Double] {
    guard channelCount > 0, frameCount > 0 else { return [] }
    var rms = Array(repeating: 0.0, count: channelCount)
    for channelIndex in 0..<channelCount {
        var sumSquares = 0.0
        let source = channels[channelIndex]
        for frameIndex in 0..<frameCount {
            let sample = source[frameIndex]
            guard sample.isFinite else { continue }
            let clamped = max(-1, min(1, sample))
            sumSquares += Double(clamped * clamped)
        }
        rms[channelIndex] = sqrt(sumSquares / Double(frameCount))
    }
    return rms
}

func writeMonoMix(channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                  selectedChannels: [Int],
                  frameCount: Int,
                  to mono: UnsafeMutablePointer<Float>) {
    guard frameCount > 0 else { return }
    let selectedChannels = selectedChannels.isEmpty ? [0] : selectedChannels
    let scale = Float(1.0 / Double(selectedChannels.count))
    for frameIndex in 0..<frameCount {
        var mixed: Float = 0
        for channelIndex in selectedChannels {
            mixed += channels[channelIndex][frameIndex] * scale
        }
        mono[frameIndex] = mixed
    }
}

// MARK: - Audio capture
//
// AVAudioEngine tap on the input node, downmix to mono / 16 kHz /
// Float32 if needed, append to a buffer while recording.
//
// Deliberately NOT @MainActor. AVAudioEngine's installTap delivers
// callbacks on an audio worker thread. Under Swift 6 strict
// concurrency, calling a @MainActor method from that thread triggers
// dispatch_assert_queue_fail (SIGTRAP) and kills the process. We
// instead guard mutable state with NSLock and let the tap callback
// run wherever AVFoundation calls it.
//
// Locking discipline: `lock` protects ALL mutable state shared with
// the render thread — `samples`, `_isRunning`, `latestLevel`,
// `latestLevelSequence`, `recordingGeneration`, the engine-open flag,
// AND the converter trio (`converter`, `converterInputFormat`,
// `manuallyMixInputToMono`). The trio is written on the main thread
// in startEngine/stopEngine and read in handleTap on AVFoundation's
// render thread; removeTap(onBus:) does NOT wait for in-flight tap
// callbacks, so an unlocked read could race stopEngine nil-ing the
// converter (an unsynchronised ARC pointer read — potential
// use-after-free). handleTap snapshots the trio once, inside the
// same lock acquisition that reads `_isRunning`, and works off the
// snapshots; a straggler callback then keeps the old converter
// alive through its own strong reference, which is safe.
// `configurationObserver` and `onConfigurationChange` are
// main-thread-only: the observer is registered with queue: .main so
// the notification callback runs on the same thread that installs
// the observer and that clears `onConfigurationChange` at
// termination.

// MARK: - Политика глушения движка (Д2)
//
// Донор держит AVAudioEngine тёплым до выхода из приложения ради экономии
// задержки на следующем нажатии — ценой постоянно открытого микрофона.
// Владелец выбирает этот размен сам; все три варианта живут за ОДНИМ
// переключателем `current` ниже, включение выбранного стоит одну строку.

/// Вариант глушения AVAudioEngine после окончания записи.
enum EngineShutdownPolicy {
    /// А: endRecording() глушит движок немедленно.
    case immediate
    /// Б: таймер бездействия — новое нажатие до истечения отменяет
    /// глушение и движок остаётся тёплым; истёк — движок глушится.
    case idleTimeout
    /// В: тёплый до выхода из приложения (поведение донора).
    case keepWarm

    /// ПЕРЕКЛЮЧАТЕЛЬ ВАРИАНТА — меняется одной строкой.
    static let current: EngineShutdownPolicy = .idleTimeout
    /// Бездействие перед глушением в варианте Б.
    static let idleTimeoutSeconds: TimeInterval = 30
}

/// Один короткий повтор даёт CoreAudio время закончить смену route, но не
/// превращает нажатие хоткея в бесконечный цикл старта.
enum AudioEngineStartRetry {
    static let maximumAttempts = 2
    static let backoffSeconds: TimeInterval = 0.1

    static func run(sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
                    start: () throws -> Void) throws {
        var attempt = 1
        while true {
            do {
                try start()
                return
            } catch {
                guard attempt < maximumAttempts else { throw error }
                sleep(backoffSeconds)
                attempt += 1
            }
        }
    }
}

enum AudioPowerEvent {
    case willSleep
    case didWake
}

enum AudioPowerAction: Equatable {
    case suspendRuntime
    case resumeListening
    case none
}

/// Защищает от дублирующихся NSWorkspace-уведомлений. Wake возвращает только
/// listener; старт записи остаётся исключительно за пользовательским hotkey.
struct AudioPowerLifecycle {
    private(set) var isSuspended = false

    mutating func transition(for event: AudioPowerEvent) -> AudioPowerAction {
        switch event {
        case .willSleep where !isSuspended:
            isSuspended = true
            return .suspendRuntime
        case .didWake where isSuspended:
            isSuspended = false
            return .resumeListening
        default:
            return .none
        }
    }
}

final class AudioCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var manuallyMixInputToMono = false
    private let lock = NSLock()
    private var samples = AudioSampleAccumulator()
    private var _isRunning = false
    private var latestLevel: Float = 0
    private var latestLevelSequence: UInt64 = 0
    private var recordingGeneration: UInt64 = 0
    private var engineStarted = false
    private var configurationObserver: NSObjectProtocol?
    private let shutdownPolicy: EngineShutdownPolicy
    private let idleTimeout: TimeInterval
    /// Отложенное глушение по таймеру бездействия (вариант Б).
    /// Читается, пишется и отменяется только под `lock`.
    private var idleStopWorkItem: DispatchWorkItem?
    #if DEBUG
    /// Тестовая опора: сколько раз политика запросила остановку движка.
    /// Железо под `swift test` недоступно (TCC микрофона), поэтому факт
    /// решения политики наблюдается этим счётчиком, а не живым движком.
    private(set) var policyStopRequestCount = 0
    #endif

    init(shutdownPolicy: EngineShutdownPolicy = EngineShutdownPolicy.current,
         idleTimeout: TimeInterval = EngineShutdownPolicy.idleTimeoutSeconds) {
        self.shutdownPolicy = shutdownPolicy
        self.idleTimeout = idleTimeout
    }

    /// Взведён ли таймер глушения по бездействию (вариант Б).
    var idleStopPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return idleStopWorkItem != nil
    }

    var onConfigurationChange: (@Sendable () -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    var isEngineStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return engineStarted
    }

    func startEngine(inputDevicePreference: String = "",
                     recordingImmediately: Bool = false) throws {
        if isEngineStarted {
            if recordingImmediately {
                beginRecording()
            }
            return
        }

        try AudioEngineStartRetry.run {
            try startEngineAttempt(inputDevicePreference: inputDevicePreference,
                                   recordingImmediately: recordingImmediately)
        }
        installConfigurationObserver()
        log("AudioCapture: engine started")
    }

    private func startEngineAttempt(inputDevicePreference: String,
                                    recordingImmediately: Bool) throws {
        let input = engine.inputNode
        var didInstallTap = false
        do {
            let selectedDevice = applyInputDevicePreference(inputDevicePreference, to: input)
            if let selectedDevice {
                waitForSelectedInputDevice(selectedDevice, on: input)
            }
            _ = try installCaptureTap(on: input)
            didInstallTap = true
            lock.lock()
            if recordingImmediately {
                cancelIdleStopLocked()
                recordingGeneration &+= 1
                samples.removeAll(keepingCapacity: true)
                latestLevel = 0
                latestLevelSequence &+= 1
                _isRunning = true
            }
            lock.unlock()

            engine.prepare()
            try engine.start()
        } catch {
            if didInstallTap {
                input.removeTap(onBus: 0)
            }
            clearStoppedCaptureState()
            resetEngineInstance()
            throw error
        }
        lock.lock()
        engineStarted = true
        lock.unlock()
    }

    func startRecording(inputDevicePreference: String = "") throws {
        if isEngineStarted {
            beginRecording()
            return
        }
        try startEngine(inputDevicePreference: inputDevicePreference,
                        recordingImmediately: true)
    }

    /// AVAudioEngine stops and uninitializes its I/O unit when a selected
    /// device changes sample rate or channel layout. Rebuild the tap and
    /// converter on the existing engine so its explicitly selected HAL
    /// device remains attached and an active recording can continue.
    func recoverAfterConfigurationChange() throws -> Bool {
        guard isEngineStarted else { return false }

        let input = engine.inputNode
        var recoveredFormat: AVAudioFormat?
        do {
            try AudioEngineStartRetry.run {
                input.removeTap(onBus: 0)
                engine.stop()
                engine.reset()

                var didInstallTap = false
                do {
                    let inputFormat = try installCaptureTap(on: input)
                    didInstallTap = true
                    engine.prepare()
                    try engine.start()
                    recoveredFormat = inputFormat
                } catch {
                    if didInstallTap {
                        input.removeTap(onBus: 0)
                    }
                    engine.stop()
                    engine.reset()
                    throw error
                }
            }
            lock.lock()
            engineStarted = true
            lock.unlock()
            let inputFormat = recoveredFormat!
            log("AudioCapture: graph recovered at \(inputFormat.sampleRate) Hz \(inputFormat.channelCount)ch")
            return true
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            removeConfigurationObserver()
            failClosedAfterConfigurationRecoveryFailure()
            resetEngineInstance()
            // Движок здесь реально остановлен (engine.stop() выше) и тап снят.
            // Без этой строки парность "started"/"stopped" ломается на аварийном
            // пути смены устройства, и машинный гейт даёт ложный красный.
            log("AudioCapture: engine stopped")
            throw error
        }
    }

    /// После двух неудачных стартов graph больше не принимает tap-данные.
    /// Уже накопленные сэмплы остаются в памяти до endRecording(), чтобы
    /// контроллер мог честно завершить текущую попытку без сырого файла.
    func failClosedAfterConfigurationRecoveryFailure() {
        lock.lock()
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        engineStarted = false
        converter = nil
        converterInputFormat = nil
        manuallyMixInputToMono = false
        lock.unlock()
    }

    func stopEngine() {
        lock.lock()
        cancelIdleStopLocked()
        lock.unlock()
        removeConfigurationObserver()

        let wasEngineStarted = isEngineStarted
        clearStoppedCaptureState()

        guard wasEngineStarted else { return }
        engine.inputNode.removeTap(onBus: 0)
        resetEngineInstance()
        // Парность с "engine started": гейт считает обе строки грепом.
        log("AudioCapture: engine stopped")
    }

    private func clearStoppedCaptureState() {
        lock.lock()
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        engineStarted = false
        // Clear the converter trio under the same lock the render
        // thread snapshots them with — removeTap below does not wait
        // for an in-flight tap callback. A callback that already took
        // its snapshot keeps the old converter alive through its own
        // strong reference, which is safe.
        converter = nil
        converterInputFormat = nil
        manuallyMixInputToMono = false
        lock.unlock()
    }

    private func resetEngineInstance() {
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
    }

    func beginRecording() {
        lock.lock()
        cancelIdleStopLocked()
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        latestLevel = 0
        latestLevelSequence &+= 1
        _isRunning = true
        lock.unlock()
    }

    private func installConfigurationObserver() {
        removeConfigurationObserver()
        // queue: .main — the notification can be posted from an
        // AVFoundation worker thread, and `onConfigurationChange` is
        // an unsynchronised var that the owner clears on the main
        // thread at termination. Hopping to the main queue makes the
        // read of the callback and the nil-ing write happen on the
        // same thread, so a config change racing teardown can never
        // observe a half-released closure.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// Stops recording and returns the captured samples.
    func endRecording() -> CapturedRecording {
        let startedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        let captured = samples.drain()
        lock.unlock()
        // Политика глушения — ПОСЛЕ того, как сэмплы забраны, и вне лока:
        // stopEngine() сам берёт `lock`.
        applyShutdownPolicyAfterRecording()
        let detachedAt = ProcessInfo.processInfo.systemUptime
        let flattened = captured.flattened()
        let flattenedAt = ProcessInfo.processInfo.systemUptime
        return CapturedRecording(
            samples: flattened,
            detachSeconds: detachedAt - startedAt,
            flattenSeconds: flattenedAt - detachedAt
        )
    }

    // MARK: - Глушение движка после записи (Д2)

    private func applyShutdownPolicyAfterRecording() {
        switch shutdownPolicy {
        case .immediate:
            policyDrivenStop()
        case .idleTimeout:
            scheduleIdleStop()
        case .keepWarm:
            break
        }
    }

    private func policyDrivenStop() {
        #if DEBUG
        lock.lock()
        policyStopRequestCount &+= 1
        lock.unlock()
        #endif
        stopEngine()
    }

    private func scheduleIdleStop() {
        let item = DispatchWorkItem { [weak self] in
            self?.idleStopFired()
        }
        lock.lock()
        cancelIdleStopLocked()
        idleStopWorkItem = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleTimeout,
                                                       execute: item)
        log("AudioCapture: engine idle stop scheduled (\(Int(idleTimeout))s)")
    }

    private func idleStopFired() {
        lock.lock()
        guard idleStopWorkItem != nil else {
            // Таймер отменён на грани исполнения (beginRecording победил).
            lock.unlock()
            return
        }
        idleStopWorkItem = nil
        let running = _isRunning
        lock.unlock()

        guard !running else {
            // Stop во время записи не рвёт запись — перевзводим таймер.
            scheduleIdleStop()
            return
        }
        policyDrivenStop()
    }

    /// Вызывается только под `lock`.
    private func cancelIdleStopLocked() {
        idleStopWorkItem?.cancel()
        idleStopWorkItem = nil
    }

    func latestRecordingLevelSnapshot() -> (level: Float, sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
            ? (latestLevel, latestLevelSequence)
            : (0, latestLevelSequence)
    }

    private func installCaptureTap(on input: AVAudioInputNode) throws -> AVAudioFormat {
        // On macOS, changing kAudioOutputUnitProperty_CurrentDevice updates
        // the input scope immediately while AVAudioInputNode's output scope
        // can keep the previous device's sample rate indefinitely. Passing
        // that stale output format to installTap raises an Objective-C
        // exception instead of returning an error. The input-scope format is
        // the actual hardware stream delivered by the selected device.
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "smltlk.Dictation.AudioCapture",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "The selected microphone has no active audio stream."]
            )
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SAMPLE_RATE,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "smltlk.Dictation.AudioCapture",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Could not create the transcription audio format."]
            )
        }

        let sourceFormat = converterSourceFormat(for: inputFormat)
        let mixToMono = inputFormat.channelCount > 1 && sourceFormat.channelCount == 1
        guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "smltlk.Dictation.AudioCapture",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Could not convert audio from the selected microphone."]
            )
        }

        // Publish the converter trio under the lock — handleTap reads
        // them on the render thread (see the locking-discipline note
        // on the class comment).
        lock.lock()
        converterInputFormat = sourceFormat
        manuallyMixInputToMono = mixToMono
        converter = newConverter
        lock.unlock()

        // Capture targetFormat by value into the closure. self is weak so
        // the engine does not keep AudioCapture alive past its owner.
        input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, target: targetFormat)
        }

        let mixLabel = mixToMono ? " via manual mono mix" : ""
        log("AudioCapture: input \(inputFormat.sampleRate) Hz \(inputFormat.channelCount)ch\(mixLabel) → \(targetFormat.sampleRate) Hz mono")
        return inputFormat
    }

    private func handleTap(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        // Snapshot the running flag AND the converter trio in one
        // lock acquisition; bail fast if we're not recording so we
        // don't pay conversion cost for nothing. Working off the
        // snapshots keeps this callback consistent even if
        // stopEngine() clears the fields mid-flight — removeTap does
        // not wait for us, and the local strong reference keeps the
        // converter alive for the rest of this call.
        lock.lock()
        let running = _isRunning
        let generation = recordingGeneration
        let converter = self.converter
        let monoMixFormat = converterInputFormat
        let mixToMono = manuallyMixInputToMono
        lock.unlock()
        guard running, let converter else { return }

        let converterInput = preparedConverterInputBuffer(from: buffer,
                                                          mixToMono: mixToMono,
                                                          monoFormat: monoMixFormat) ?? buffer
        let ratio = target.sampleRate / converterInput.format.sampleRate
        let outCap = AVAudioFrameCount(Double(converterInput.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }

        // .noDataNow vs .endOfStream: this is reusing the same
        // AVAudioConverter across every tap callback (~50 Hz). If we
        // signal .endOfStream after the buffer, the converter goes
        // into a terminal state and produces 0 samples on every
        // subsequent call — exactly the "first capture was 0.10s,
        // every press after that was 0.00s" bug we saw before this
        // fix. .noDataNow means "I'm out of input *for this call*,
        // but the stream continues" and leaves the converter usable.
        let inputProvider = AudioConverterInputProvider(buffer: converterInput)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            inputProvider.provide(outStatus: outStatus)
        }
        if status == .error {
            log("AudioCapture: convert error: \(error?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let frameCount = Int(out.frameLength)
        var arr: [Float] = []
        arr.reserveCapacity(frameCount)
        var sumSquares: Double = 0
        var finiteSampleCount = 0
        for sample in UnsafeBufferPointer(start: ch, count: frameCount) {
            arr.append(sample)
            guard sample.isFinite else { continue }
            let clamped = max(-1, min(1, sample))
            sumSquares += Double(clamped * clamped)
            finiteSampleCount += 1
        }
        let level = normalizedAudioLevel(sumSquares: sumSquares,
                                         sampleCount: finiteSampleCount)
        // Re-check running under lock — endRecording() might have
        // fired during conversion, then a rapid next recording may
        // already have started. The generation token keeps straggler
        // frames out of the next clip.
        lock.lock()
        if _isRunning && recordingGeneration == generation {
            samples.append(arr)
            latestLevel = level
            latestLevelSequence &+= 1
        }
        lock.unlock()
    }

    private func converterSourceFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
        guard inputFormat.channelCount > 1,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: inputFormat.sampleRate,
                                             channels: 1,
                                             interleaved: false) else {
            return inputFormat
        }
        return monoFormat
    }

    /// `mixToMono` / `monoFormat` are the caller's lock-held
    /// snapshots of `manuallyMixInputToMono` / `converterInputFormat`
    /// — this runs on the render thread and must not read the shared
    /// fields directly (see the locking-discipline note on the class
    /// comment).
    private func preparedConverterInputBuffer(from buffer: AVAudioPCMBuffer,
                                              mixToMono: Bool,
                                              monoFormat: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard mixToMono else { return buffer }
        guard let monoFormat,
              let channels = buffer.floatChannelData else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 1, frameCount > 0 else { return buffer }
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                         frameCapacity: AVAudioFrameCount(frameCount)),
              let mono = out.floatChannelData?[0] else {
            return nil
        }

        let rms = channelRMSValues(channels: channels,
                                   channelCount: channelCount,
                                   frameCount: frameCount)
        writeMonoMix(channels: channels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: rms),
                     frameCount: frameCount,
                     to: mono)
        out.frameLength = AVAudioFrameCount(frameCount)
        return out
    }

    private func applyInputDevicePreference(_ preference: String,
                                            to input: AVAudioInputNode) -> AudioInputDevice? {
        let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !isDefaultAggregateAudioInputPreference(trimmed) else { return nil }

        guard let device = audioInputDevice(matching: trimmed) else {
            log("AudioCapture: saved input device unavailable, using system default")
            return nil
        }
        guard let unit = input.audioUnit else {
            log("AudioCapture: input audio unit unavailable, using system default")
            return nil
        }

        if currentAudioInputDeviceID(for: unit) == device.id {
            log("AudioCapture: selected input \(device.name) already active")
            return device
        }

        var deviceID = device.id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            log("AudioCapture: input device switch failed (\(formattedOSStatus(status))), using system default")
            return nil
        }
        log("AudioCapture: selected input \(device.name)")
        return device
    }

    private func waitForSelectedInputDevice(_ device: AudioInputDevice,
                                            on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }

        let expectedRate = audioInputDeviceNominalSampleRate(device.id)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var lastDeviceID = currentAudioInputDeviceID(for: unit)
        var lastFormat = input.inputFormat(forBus: 0)

        while ProcessInfo.processInfo.systemUptime < deadline {
            lastDeviceID = currentAudioInputDeviceID(for: unit)
            lastFormat = input.inputFormat(forBus: 0)
            let rateIsReady = expectedRate.map {
                abs(lastFormat.sampleRate - $0) < 0.5
            } ?? (lastFormat.sampleRate > 0)

            if lastDeviceID == device.id,
               lastFormat.channelCount > 0,
               rateIsReady {
                log("AudioCapture: selected input ready at \(lastFormat.sampleRate) Hz \(lastFormat.channelCount)ch")
                return
            }
            Thread.sleep(forTimeInterval: 0.025)
        }

        let expected = expectedRate.map { "\($0) Hz" } ?? "an active format"
        log("AudioCapture: selected input route still settling; device=\(lastDeviceID ?? 0), format=\(lastFormat.sampleRate) Hz \(lastFormat.channelCount)ch, expected \(expected)")
    }
}

final class AudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provide(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if didProvideBuffer {
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideBuffer = true
        outStatus.pointee = .haveData
        return buffer
    }
}
