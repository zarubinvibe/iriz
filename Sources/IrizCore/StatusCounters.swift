// Машинно-читаемый снимок состояния: счётчики доставки надиктовки и сборка
// полезной нагрузки status.json. Свой код.
//
// Почему здесь, а не в IrizApp: писатель status.json живёт в исполняемой
// цели, которую тестами не достать. Решение (что попадает в снимок) и счёт
// (сколько вставок не подтвердилось) — здесь, в тестируемой библиотеке.
import Foundation

/// Счётчики доставки текста: сколько вставок пытались и сколько НЕ подтвердились.
///
/// Только числа — ни одного продиктованного слова (приватность: то же
/// требование, что у Counters). Живут в UserDefaults, а не файлом рядом с
/// расшифровками: снимок status.json их просто читает, а тестам достаточно
/// своего `UserDefaults(suiteName:)`.
/// `@unchecked Sendable` по той же причине, что у DictationSettings: сам
/// UserDefaults потокобезопасен, а Sendable ему не проставили.
public struct InsertionStats: @unchecked Sendable {
    public static let attemptsKey = "ru.smltlk.insertionAttempts"
    public static let failuresKey = "ru.smltlk.insertionFailures"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Ключ счётчика по ПРИЧИНЕ отказа.
    ///
    /// Зачем отдельно от общего числа. У владельца на 03.09.2026 стояло
    /// `attempts = 1305`, `failures = 76` - 5,8 % надиктовок не доехали до
    /// поля. Разобрать этот процент было НЕЧЕМ: `record(delivered:)` сводил
    /// три разных исхода в один булев флаг, а три исхода лечатся по-разному.
    /// Хуже того, один из них - `deliveryNotObservable` - вообще не отказ:
    /// сработал прямой ввод юникодом, где факт забора текста наблюдать нечем,
    /// и он завышал долю провалов молча.
    public static func failureKey(_ reason: String) -> String {
        "ru.smltlk.insertionFailure.\(reason)"
    }

    /// Надиктовок, где вставлять было НЕЧЕГО: обработка вернула пустую строку.
    /// Это не отказ вставки, и в `attempts` такой случай не попадает вовсе -
    /// но на диске он неотличим от отказа, потому что `inserted.txt` не
    /// появляется и там, и там. Замер 03.09.2026: 196 каталогов из 1561
    /// (12,6 %) без `inserted.txt` против 5,8 % по счётчику. Пока причина не
    /// пишется, эти два числа спорят друг с другом, и оба недоказуемы.
    public static let nothingToInsertKey = "ru.smltlk.insertionNothingToInsert"

    public var attempts: Int { max(0, defaults.integer(forKey: Self.attemptsKey)) }
    public var failures: Int { max(0, defaults.integer(forKey: Self.failuresKey)) }
    public var nothingToInsert: Int { max(0, defaults.integer(forKey: Self.nothingToInsertKey)) }

    /// Сколько отказов пришлось на названную причину.
    public func failures(reason: String) -> Int {
        max(0, defaults.integer(forKey: Self.failureKey(reason)))
    }

    /// Учитывает исход одной вставки и возвращает новые значения счётчиков.
    ///
    /// Общий ключ `failures` НЕ переименован и не обнулён намеренно: в нём
    /// лежит история владельца, и терять её ради красоты нельзя. Разбивка
    /// добавляется рядом и наполняется с этого релиза.
    @discardableResult
    public func record(delivered: Bool, reason: String? = nil) -> (attempts: Int, failures: Int) {
        let nextAttempts = attempts + 1
        defaults.set(nextAttempts, forKey: Self.attemptsKey)
        guard !delivered else { return (nextAttempts, failures) }
        let nextFailures = failures + 1
        defaults.set(nextFailures, forKey: Self.failuresKey)
        if let reason {
            let key = Self.failureKey(reason)
            defaults.set(max(0, defaults.integer(forKey: key)) + 1, forKey: key)
        }
        return (nextAttempts, nextFailures)
    }

    /// Надиктовка сохранена, а вставлять было нечего.
    @discardableResult
    public func recordNothingToInsert() -> Int {
        let next = nothingToInsert + 1
        defaults.set(next, forKey: Self.nothingToInsertKey)
        return next
    }

    /// Разбивка для снимка состояния: причина -> сколько раз.
    public func failureBreakdown(reasons: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for reason in reasons {
            let value = failures(reason: reason)
            if value > 0 { out[reason] = value }
        }
        return out
    }
}

/// Причины отказа вставки, которые умеет различать продукт. Список держится
/// здесь, а не в `IrizDictate`: снимок состояния живёт в ядре и о движке
/// диктовки ничего не знает.
public let INSERTION_FAILURE_REASONS = [
    "insertionFailed",
    "targetNeverRequestedText",
    "deliveryNotObservable",
    "waiting",
]

/// Полезная нагрузка status.json — опора scripts/gate_app.sh и gate_defects.sh.
/// Существующие ключи (ax/listen/post/loginItem/version) не переименованы:
/// их читают скрипты гейта.
public func statusReportJSONData(ax: Bool,
                                 listen: Bool,
                                 post: Bool,
                                 loginItem: Bool,
                                 version: String,
                                 insertionAttempts: Int,
                                 insertionFailures: Int,
                                 insertionFailureReasons: [String: Int] = [:],
                                 insertionNothingToInsert: Int = 0) -> Data? {
    let payload: [String: Any] = [
        "ax": ax,
        "listen": listen,
        "post": post,
        "loginItem": loginItem,
        "version": version,
        "insertionAttempts": max(0, insertionAttempts),
        "insertionFailures": max(0, insertionFailures),
        // Разбивка по причинам: без неё процент отказов недиагностируем.
        "insertionFailureReasons": insertionFailureReasons.mapValues { max(0, $0) },
        "insertionNothingToInsert": max(0, insertionNothingToInsert),
    ]
    return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
}
