// Протокол встречи: реплики превращаются в документ.
//
// Чистая сборка текста, без файлов и без движков: протокол заседания читает
// человек и подшивает к делу, поэтому его форма обязана быть проверяемой
// пробой, а не «получилось как получилось».
//
// ЧТО ДЕЛАЕТ ЭТОТ ФАЙЛ И ЧЕГО НЕ ДЕЛАЕТ.
//
// Делает: собирает реплики в документ с шапкой, участниками и временными
// метками. Всё - механика, и вся она на этой машине.
//
// НЕ делает: не пересказывает, не выделяет решения и задачи, не сокращает.
// Это работа для понимания смысла, и она уходит внешнему агенту - тому же, что
// чистит речь, но по ОТДЕЛЬНОМУ согласию на текст встречи. Молча пересказывать заседание
// нельзя: пересказ, который никто не заказывал, в деле опаснее его отсутствия.
import Foundation

/// Метка времени вида 00:04:12. Часы показываются всегда: заседание идёт
/// часами, и «04:12» на третьем часу читается неверно.
public func meetingTimestamp(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds < Double(Int.max) else { return "таймкод не установлен" }
    let total = Int(max(0, seconds).rounded(.down))
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

/// Шапка и тело протокола.
public struct MeetingProtocolDocument: Equatable, Sendable {
    public let title: String
    public let recordedAt: Date?
    public let audioSeconds: Double
    public let turns: [SpeakerTurn]

    public init(title: String, recordedAt: Date?, audioSeconds: Double, turns: [SpeakerTurn]) {
        self.title = title
        self.recordedAt = recordedAt
        self.audioSeconds = audioSeconds
        self.turns = turns
    }

    /// Участники в порядке первого появления, а не по алфавиту: порядок
    /// вступления сам по себе сведения о встрече.
    public var participants: [String] {
        var seen: Set<String> = []
        var order: [String] = []
        for turn in turns where !turn.speaker.isEmpty && !seen.contains(turn.speaker) {
            seen.insert(turn.speaker)
            order.append(turn.speaker)
        }
        return order
    }

    /// Готовый текст протокола.
    public func text(formatter: DateFormatter = meetingDateFormatter()) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("Запись: \(recordedAt.map { formatter.string(from: $0) } ?? "дата встречи не указана")")
        lines.append("Длительность: \(meetingTimestamp(audioSeconds))")
        lines.append("Автоматическая расшифровка доступного файла; не сверена человеком с аудио. Полнота записи всей встречи требует уточнения.")
        if participants.isEmpty {
            // Пустое место хуже честной строки: читатель должен понять, что
            // говорящих не разобрали, а не гадать, почему их нет.
            lines.append("Участники: не разобраны")
        } else {
            lines.append("Участники: \(participants.joined(separator: ", "))")
        }
        lines.append("")
        if turns.isEmpty {
            lines.append("Речь не распознана.")
        }
        for turn in turns {
            let speaker = turn.speaker.isEmpty ? "Говорящий не определён" : turn.speaker
            let timing = turn.hasKnownTiming ? meetingTimestamp(turn.start) : "таймкод не установлен"
            lines.append("**\(speaker)** [\(timing)]")
            lines.append(turn.text)
            lines.append("")
        }
        // Хвост без лишней пустой строки: файл, который каждый раз разный на
        // невидимый символ, шумит в истории изменений.
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }
}

public func meetingDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "d MMMM yyyy, HH:mm"
    return formatter
}
