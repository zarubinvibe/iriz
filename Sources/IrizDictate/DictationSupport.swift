// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4.
// Константы конвейера диктовки и мелкие хелперы без состояния.
import CoreGraphics
import Foundation

let SAMPLE_RATE: Double = 16_000
let MAX_RECORDING_SECONDS: TimeInterval = 20 * 60   // auto-release if held longer
public let DEFAULT_HOTKEY_KEYCODE: CGKeyCode = 54  // Right Command
public let RIGHT_COMMAND_KEYCODE: CGKeyCode = 54
public let ESCAPE_KEYCODE: CGKeyCode = 53
let RETURN_KEYCODE: CGKeyCode = 36
let ENTER_AFTER_INSERT_DELAY_NANOSECONDS: UInt64 = 120_000_000
let MIN_CLIP_SECONDS: Double = 0.25

let MAX_INPUT_DEVICE_PREFERENCE_BYTES = 512
let MAX_TRANSCRIPT_CORRECTIONS = 512
let MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES = 512
let MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES = 4096

// Заготовки. Тело крупнее замены на порядок: туда кладут шапку документа
// или блок реквизитов, а не одно слово. Список короче словарного: заготовку
// надо помнить наизусть, чтобы произнести, и сотня — уже больше, чем человек
// удержит в голове.
let MAX_DICTATION_SNIPPETS = 128
let MAX_DICTATION_SNIPPET_TRIGGER_BYTES = 512
let MAX_DICTATION_SNIPPET_BODY_BYTES = 16_384

func millisecondsLabel(_ duration: Double) -> String {
    String(format: "%.1f ms", max(0, duration) * 1_000)
}

// MARK: - Уровень звука (индикация записи)

func normalizedAudioLevel(from samples: [Float]) -> Float {
    var sumSquares: Double = 0
    var count = 0

    for sample in samples where sample.isFinite {
        let clamped = max(-1, min(1, sample))
        sumSquares += Double(clamped * clamped)
        count += 1
    }

    return normalizedAudioLevel(sumSquares: sumSquares, sampleCount: count)
}

func normalizedAudioLevel(sumSquares: Double, sampleCount: Int) -> Float {
    guard sampleCount > 0, sumSquares > 0 else { return 0 }
    let rms = sqrt(sumSquares / Double(sampleCount))
    guard rms.isFinite, rms > 0 else { return 0 }

    // This is a voice-visibility meter, not a calibrated VU meter.
    // Keep low room tone calm, then aggressively lift speech-range RMS
    // so normal close-mic speech visibly opens the HUD without shouting.
    let decibels = 20 * log10(rms)
    let gated = (decibels + 52) / 20
    guard gated > 0.06 else { return 0 }
    let lifted = pow(max(0, min(1, gated)), 0.42)
    return Float(max(0, min(1, lifted)))
}

// MARK: - OSStatus-хелперы (ошибки CoreAudio в лог)

func fourCharacterCodeString(forRawOSStatus raw: UInt32) -> String? {
    let bytes = [
        UInt8((raw >> 24) & 0xff),
        UInt8((raw >> 16) & 0xff),
        UInt8((raw >> 8) & 0xff),
        UInt8(raw & 0xff),
    ]
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return nil }
    return String(bytes: bytes, encoding: .ascii)
}

func formattedOSStatusCode(_ code: Int) -> String {
    let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: code))
    let hex = String(format: "0x%08x", raw)
    if let fourCharacterCode = fourCharacterCodeString(forRawOSStatus: raw) {
        return "OSStatus \(code) (\(hex), '\(fourCharacterCode)')"
    }
    return "OSStatus \(code) (\(hex))"
}

func formattedOSStatus(_ status: OSStatus) -> String {
    formattedOSStatusCode(Int(status))
}
