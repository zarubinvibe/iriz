// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4.
// Звуковая обратная связь: старт записи, готово, ошибка.
import AppKit

@MainActor
enum Sounds {
    private static let start = systemSound("Tink", volume: 0.55)
    private static let done = systemSound("Pop", volume: 0.45)
    private static let error = systemSound("Basso", volume: 0.30)

    private static func systemSound(_ name: String, volume: Float) -> NSSound? {
        let path = "/System/Library/Sounds/\(name).aiff"
        guard let sound = NSSound(contentsOfFile: path, byReference: true) else { return nil }
        sound.volume = volume
        return sound
    }

    static func playStart() { start?.stop(); start?.play() }
    static func playDone()  { done?.stop();  done?.play() }
    static func playError() { error?.stop(); error?.play() }
}
