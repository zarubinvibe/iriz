// Коннекторы наружу: календарь Google и Zoom.
//
// Это единственная часть продукта, которая ходит в чужие сервисы от имени
// владельца, и потому она устроена жёстче остальных.
//
// ТРИ ПРАВИЛА, И НИ ОДНО НЕ НАСТРАИВАЕТСЯ.
//
// 1. Согласие ПОКОННЕКТОРНОЕ и по умолчанию его нет. Включённый календарь не
//    включает Zoom: это разные сервисы, разные данные и разные последствия.
// 2. Предупреждение приходит ИЗ САМОГО КОННЕКТОРА, а не из отдельного списка.
//    Список предупреждений, который ведут отдельно, расходится со списком
//    коннекторов на первой же правке, и расходится молча.
// 3. Обычная диктовка коннекторов не касается вовсе. Наружу ходят только те
//    режимы, где владелец дал согласие явно, и он видит это до отправки.
//
// Слова владельца, из которых выросли правила: «необходимо добавить коннекторы
// Google и Zoom наружу... на обычной диктовке нет, но на других, на которых это
// согласовано, и в тексте есть предупреждение о том, что начнёт уходить наружу,
// я не против».
import Foundation

public enum IrizConnector: String, CaseIterable, Codable, Sendable {
    case googleCalendar
    case zoom

    public var title: String {
        switch self {
        case .googleCalendar: return "Календарь Google"
        case .zoom: return "Zoom"
        }
    }

    /// Что коннектор ЧИТАЕТ у сервиса. Названо словами, потому что человек
    /// соглашается на конкретное, а не на «интеграцию».
    public var reads: String {
        switch self {
        case .googleCalendar:
            return "названия и время встреч в календаре"
        case .zoom:
            return "список встреч и облачные записи с расшифровками"
        }
    }

    /// Что уходит НАРУЖУ. Пустая строка означала бы коннектор, который только
    /// читает, и такой в этом списке пока один.
    public var sends: String {
        switch self {
        case .googleCalendar:
            return "название встречи и ссылка на её протокол"
        case .zoom:
            return "ничего: записи только скачиваются"
        }
    }

    /// Предупреждение перед включением. Собирается из полей выше, а не пишется
    /// отдельной строкой: разъехаться им тогда негде.
    public var warning: String {
        "Коннектор читает \(reads). Наружу уходит: \(sends). "
            + "Обычная диктовка через коннекторы не проходит никогда."
    }

    /// Что владелец обязан завести САМ, прежде чем это заработает.
    ///
    /// Приложение не может создать эти учётные записи за него: сервисы требуют
    /// живого человека с договором. Молчать об этом нельзя - иначе коннектор
    /// выглядит сломанным, хотя он просто не подключён.
    public var ownerMustProvide: String {
        switch self {
        case .googleCalendar:
            return "проект в Google Cloud с включённым Calendar API и клиент OAuth "
                + "типа «Desktop app»"
        case .zoom:
            return "приложение в Zoom Marketplace типа «General app» с правами "
                + "meeting:read и recording:read"
        }
    }
}

/// Согласия на коннекторы. Отдельный тип, а не словарь в настройках: у него
/// одна работа, и её видно.
public struct IrizConnectorConsent: Codable, Equatable, Sendable {
    private var allowed: Set<String>

    public init(allowed: Set<String> = []) {
        self.allowed = allowed
    }

    public func isAllowed(_ connector: IrizConnector) -> Bool {
        allowed.contains(connector.rawValue)
    }

    public mutating func set(_ connector: IrizConnector, allowed value: Bool) {
        if value {
            allowed.insert(connector.rawValue)
        } else {
            allowed.remove(connector.rawValue)
        }
    }

    /// Ни одного согласия. Умолчание именно такое, и проба это стережёт:
    /// коннектор, включённый по умолчанию, это отправка данных без спроса.
    public var isEmpty: Bool { allowed.isEmpty }
}
