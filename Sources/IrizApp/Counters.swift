import Foundation

/// Дневные агрегаты набора: слов, автопереключений, отмен. Только счётчики —
/// ни одного набранного слова на диск (требование приватности плана, этап 5.7).
@MainActor
final class Counters {
    static let shared = Counters()

    private struct Day: Codable {
        var date: String
        var words: Int
        var autoswitches: Int
        var undos: Int
    }

    private struct File: Codable {
        var days: [Day]
    }

    private var file: File
    private let url: URL

    private init() {
        url = SupportPaths.dir.appendingPathComponent("counters.json")
        let decoded = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        file = decoded ?? File(days: [])
    }

    func bumpWords() { bump(\.words) }
    func bumpAutoswitch() { bump(\.autoswitches) }
    func bumpUndo() { bump(\.undos) }

    /// Агрегаты сегодняшнего дня — строка статистики в меню.
    var today: (autoswitches: Int, undos: Int) {
        guard let day = file.days.first(where: { $0.date == Self.todayString() }) else {
            return (0, 0)
        }
        return (day.autoswitches, day.undos)
    }

    private func bump(_ keyPath: WritableKeyPath<Day, Int>) {
        let today = Self.todayString()
        if let index = file.days.firstIndex(where: { $0.date == today }) {
            file.days[index][keyPath: keyPath] += 1
        } else {
            var day = Day(date: today, words: 0, autoswitches: 0, undos: 0)
            day[keyPath: keyPath] = 1
            file.days.append(day)
        }
        // Агрегаты нужны для приёмочного окна — древние дни не храним.
        if file.days.count > 90 { file.days.removeFirst(file.days.count - 90) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
