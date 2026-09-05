// Честные цифры для отчёта пакетной расшифровки: сколько звука, сколько
// прошло, сколько осталось, во сколько раз быстрее записи.
//
// ПРАВИЛО. Пока мерить нечем — оценки НЕТ (`nil`), а не «примерно 0 с».
// Придуманный прогресс — та же ложь, что придуманный текст.
import Foundation

/// «1 ч 04 мин», «3 мин 21 с», «0,4 с» — как сказал бы человек.
public func humanDurationLabel(seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0 с" }
    if seconds < 10 {
        return decimalLabel(seconds, digits: 1) + " с"
    }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let rest = total % 60
    if hours > 0 {
        return String(format: "%d ч %02d мин", hours, minutes)
    }
    if minutes > 0 {
        return String(format: "%d мин %02d с", minutes, rest)
    }
    return "\(rest) с"
}

/// «в 12,6 раза быстрее записи». `nil`, если делить не на что.
public func speedFactor(audioSeconds: Double, processingSeconds: Double) -> Double? {
    guard audioSeconds.isFinite, processingSeconds.isFinite,
          audioSeconds > 0, processingSeconds > 0 else { return nil }
    return audioSeconds / processingSeconds
}

/// Сколько ещё ждать, если доля `doneFraction` заняла `elapsedSeconds`.
///
/// До 5 % пройденного оценка — гадание (первый кусок звука идёт вместе с
/// прогревом), поэтому возвращается `nil` и вызывающий честно молчит.
public func remainingSecondsEstimate(doneFraction: Double, elapsedSeconds: Double) -> Double? {
    guard doneFraction.isFinite, elapsedSeconds.isFinite,
          doneFraction >= 0.05, doneFraction < 1, elapsedSeconds > 0 else { return nil }
    let total = elapsedSeconds / doneFraction
    let remaining = total - elapsedSeconds
    return remaining.isFinite ? max(0, remaining) : nil
}

/// Сколько ждать весь остаток пачки, если известна измеренная скорость.
/// `nil`, пока ни одного файла не измерено.
public func remainingBatchSecondsEstimate(remainingAudioSeconds: Double,
                                          measuredSpeedFactor: Double?) -> Double? {
    guard let measuredSpeedFactor, measuredSpeedFactor > 0,
          remainingAudioSeconds.isFinite, remainingAudioSeconds > 0 else { return nil }
    return remainingAudioSeconds / measuredSpeedFactor
}

/// Число с запятой, как принято по-русски.
public func decimalLabel(_ value: Double, digits: Int) -> String {
    String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
}
