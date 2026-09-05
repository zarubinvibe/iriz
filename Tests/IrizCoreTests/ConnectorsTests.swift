// Проба согласий на коннекторы.
//
// Это единственная часть продукта, которая ходит в чужие сервисы от имени
// владельца. Судится не работа коннектора, а то, что его нельзя включить
// молча и нельзя включить оптом.
import Foundation
import Testing

@testable import IrizCore

@Suite("Согласия на коннекторы")
struct ConnectorsTests {
    @Test("по умолчанию не разрешён ни один")
    func поУмолчаниюНиОдин() {
        // Коннектор, включённый по умолчанию, это отправка данных без спроса.
        let consent = IrizConnectorConsent()
        #expect(consent.isEmpty)
        for connector in IrizConnector.allCases {
            #expect(consent.isAllowed(connector) == false)
        }
    }

    @Test("согласие поконнекторное, а не общее")
    func согласиеПоконнекторное() {
        // Включённый календарь не включает Zoom: разные сервисы, разные данные,
        // разные последствия.
        var consent = IrizConnectorConsent()
        consent.set(.googleCalendar, allowed: true)
        #expect(consent.isAllowed(.googleCalendar))
        #expect(consent.isAllowed(.zoom) == false)
    }

    @Test("согласие снимается")
    func согласиеСнимается() {
        var consent = IrizConnectorConsent()
        consent.set(.zoom, allowed: true)
        consent.set(.zoom, allowed: false)
        #expect(consent.isEmpty)
    }

    @Test("согласие переживает запись на диск")
    func согласиеПереживаетЗапись() throws {
        var consent = IrizConnectorConsent()
        consent.set(.zoom, allowed: true)
        let data = try JSONEncoder().encode(consent)
        let restored = try JSONDecoder().decode(IrizConnectorConsent.self, from: data)
        #expect(restored.isAllowed(.zoom))
        #expect(restored.isAllowed(.googleCalendar) == false)
    }

    @Test("предупреждение собрано из полей коннектора и называет обе стороны")
    func предупреждениеНазываетОбеСтороны() {
        // Список предупреждений, который ведут отдельно, расходится со списком
        // коннекторов на первой же правке, и расходится молча.
        for connector in IrizConnector.allCases {
            #expect(connector.warning.contains(connector.reads))
            #expect(connector.warning.contains(connector.sends))
            #expect(connector.warning.contains("Обычная диктовка"))
        }
    }

    @Test("у каждого коннектора названо, что владелец заводит сам")
    func названоЧтоЗаводитВладелец() {
        // Молчать об этом нельзя: иначе коннектор выглядит сломанным, хотя он
        // просто не подключён.
        for connector in IrizConnector.allCases {
            #expect(!connector.ownerMustProvide.isEmpty)
        }
    }

    @Test("незнакомое согласие из будущей версии не включает коннектор")
    func незнакомоеСогласиеНеВключает() throws {
        // Запись из чужого профиля или из будущей версии не имеет права
        // включить отправку данных.
        let data = Data(#"{"allowed":["telepathy"]}"#.utf8)
        let consent = try JSONDecoder().decode(IrizConnectorConsent.self, from: data)
        for connector in IrizConnector.allCases {
            #expect(consent.isAllowed(connector) == false)
        }
    }
}
