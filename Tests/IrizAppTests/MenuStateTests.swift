// Решения меню строки меню.
//
// Живое меню под тест-раннером не поднять, но решения в нём чистые: что
// написано в заголовке, как склоняется счётчик, что стоит справа у строки
// «Диктовка», когда появляется аварийная строка и что произносит VoiceOver.
// До этой волны их не проверял никто - у `IrizApp` не было тестовой цели.
import IrizCore
import Foundation
import Testing

@testable import IrizApp
@testable import IrizDictate

@Suite("меню: заголовок и статистика")
@MainActor
struct MenuStateHeroTests {

    private func state() -> MenuState {
        let s = MenuState()
        s.accessibilityOK = true
        s.inputMonitoringOK = true
        s.microphoneOK = true
        s.currentLayoutName = "Русская"
        s.dictationState = .ready
        return s
    }

    @Test func заголовокОтвечаетЧтоСейчас() {
        let s = state()
        s.mode = .fixing
        #expect(s.heroTitle == "Исправляет")
        #expect(s.heroDetail == " · Русская")
    }

    @Test func диктовкаЗабираетСлотЗаголовка() {
        // Пока идёт речь, слот принадлежит диктовке: режим раскладки в этот
        // момент не то, чем приложение занято.
        let s = state()
        s.mark = MarkState(mode: .dictating, alarm: .none)
        #expect(s.heroTitle == "Слушает")
        #expect(s.heroDetail == " · речь в текст")
    }

    @Test func безРаскладкиХвостаНет() {
        let s = state()
        s.currentLayoutName = ""
        #expect(s.heroDetail == "")
    }

    @Test func счётчикСклоняетсяПоРусски() {
        let s = state()
        s.mode = .fixing
        for (n, word) in [(1, "исправление"), (2, "исправления"), (5, "исправлений"),
                          (11, "исправлений"), (21, "исправление"), (104, "исправления")] {
            s.todayAutoswitches = n
            #expect(s.statsLine.contains("\(n) \(word)"), "\(n) -> \(word)")
        }
    }

    @Test func вРежимеСчётаЭтоНеИсправления() {
        // Правок не было вовсе, и называть замеченное исправлениями было бы враньём.
        let s = state()
        s.mode = .shadow
        s.todayAutoswitches = 3
        #expect(s.statsLine.contains("ошибки раскладки"))
        #expect(!s.statsLine.contains("исправления"))
    }
}

@Suite("меню: обещания и аварии")
@MainActor
struct MenuStatePromiseTests {

    private func state() -> MenuState {
        let s = MenuState()
        s.accessibilityOK = true
        s.inputMonitoringOK = true
        s.microphoneOK = true
        s.currentLayoutName = "Русская"
        s.dictationState = .ready
        return s
    }

    @Test func клавишаПоказываетсяТолькоКогдаСработает() {
        // Клавиша рядом с неработающей функцией и есть обещание впустую -
        // дефект, на котором проект горел четырежды.
        let s = state()
        #expect(s.dictationHint == .key)

        s.microphoneOK = false
        #expect(s.dictationHint == .fault("нет доступа к микрофону"))

        s.microphoneOK = true
        s.dictationState = .warmingUp
        #expect(s.dictationHint == .note("прогревается"))

        s.dictationState = .unavailable("нет мониторинга ввода")
        #expect(s.dictationHint == .fault("нет мониторинга ввода"))
    }

    @Test func обИсправностиНеДокладывают() {
        let s = state()
        #expect(s.permissionAlarm == nil)

        s.accessibilityOK = false
        #expect(s.permissionAlarm == "Нет доступа к Универсальному доступу")

        s.accessibilityOK = true
        s.inputMonitoringOK = false
        #expect(s.permissionAlarm == "Нет доступа к Мониторингу ввода")
    }

    @Test func отвалившийсяТапВидноОтдельноОтРазрешений() {
        // Разрешения на месте, а слежение отвалилось: разные поломки лечатся
        // по-разному, и валить их в одну строку значит отправить владельца
        // чинить не то. Прежде тап молча пытались включить обратно и считали
        // попытку успехом.
        let s = state()
        #expect(s.permissionAlarm == nil)

        s.inputTapOK = false
        #expect(s.permissionAlarm == "Слежение за клавишами отвалилось")
        // Снимок дважды ловил обрезанный хвост: сначала на одной строке, потом
        // на двух. Потолок снят с кадра - две строки панели 300 pt держат
        // около 56 знаков, и все аварийные строки обязаны быть внутри.
        for alarm in ["Нет доступа к Универсальному доступу",
                      "Нет доступа к Мониторингу ввода",
                      "Слежение за клавишами отвалилось"] {
            #expect(alarm.count <= 44, "аварийная строка не влезет в панель: \(alarm)")
        }

        // Когда нет и разрешения, первым называется оно: чинить надо его.
        s.accessibilityOK = false
        #expect(s.permissionAlarm == "Нет доступа к Универсальному доступу")
    }

    @Test func voiceOverНазываетОтвалившийсяТапСвоейФразой() {
        let s = state()
        s.inputTapOK = false
        s.mark = MarkState(mode: .fixing, alarm: .noPermission)
        #expect(s.accessibilityLabel == "\(IRIZ_NAME): слежение за клавишами отвалилось")
    }

    @Test func раскладкаТребуетОбоихРазрешений() {
        let s = state()
        #expect(s.permissionsOK)
        s.inputMonitoringOK = false
        #expect(!s.permissionsOK)
    }

    @Test func voiceOverНазываетВсеСостоянияПоРазному() {
        // Глиф - единственный носитель состояния, без подписи он для VoiceOver нем.
        let s = state()
        var labels: Set<String> = []

        s.mode = .fixing
        labels.insert(s.accessibilityLabel)
        s.mode = .paused
        labels.insert(s.accessibilityLabel)
        s.mark = MarkState(mode: .dictating, alarm: .none)
        labels.insert(s.accessibilityLabel)
        s.mark = MarkState(mode: .fixing, alarm: .noPermission)
        labels.insert(s.accessibilityLabel)
        s.mark = MarkState(mode: .fixing, alarm: .none)
        s.microphoneOK = false
        labels.insert(s.accessibilityLabel)

        #expect(labels.count == 5, "состояния обязаны звучать по-разному: \(labels)")
        // Имя берётся из константы, а не из литерала: тест, знающий имя
        // наизусть, при следующем переезде промолчит вместе с кодом.
        for label in labels { #expect(label.hasPrefix("\(IRIZ_NAME): ")) }
    }
}
