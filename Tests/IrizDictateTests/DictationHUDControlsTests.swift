// Проба меню плашки.
//
// Судится СОСТАВ меню и то, что оно правда меняет язык. Открывать его мышью
// под тестом нечем, но собирается оно чистой функцией - ровно затем, чтобы
// проверялось без окна.
import AppKit
import Testing

@testable import IrizDictate

@MainActor
@Suite("Меню плашки")
struct DictationHUDControlsTests {
    private final class Box {
        var language: DictationLanguage = .russian
        var size: DictationHUDSizeChoice = .medium
        var settingsOpened = 0
        var historyOpened = 0
    }

    private func controls(_ box: Box) -> DictationHUDControls {
        DictationHUDControls(
            currentLanguage: { box.language },
            setLanguage: { box.language = $0 },
            currentSize: { box.size },
            setSize: { box.size = $0 },
            openSettings: { box.settingsOpened += 1 },
            openHistory: { box.historyOpened += 1 }
        )
    }

    @Test("в меню есть язык, история и настройки")
    func составМеню() {
        let menu = makeDictationHUDMenu(controls: controls(Box()))
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Язык распознавания"))
        #expect(titles.contains("История надиктовок"))
        #expect(titles.contains("Настройки…"))
    }

    @Test("галочка стоит на текущем языке")
    func галочкаНаТекущем() {
        // Меню без отметки заставляет владельца помнить, на чём он
        // остановился, а открывает он его как раз потому, что не помнит.
        let box = Box()
        box.language = .english
        let menu = makeDictationHUDMenu(controls: controls(box))
        let languages = menu.items.first { $0.title == "Язык распознавания" }?.submenu
        let checked = languages?.items.filter { $0.state == .on }.map(\.title)
        #expect(checked == ["Английский"])
    }

    @Test("выбор пункта меняет язык")
    func выборМеняетЯзык() {
        let box = Box()
        let menu = makeDictationHUDMenu(controls: controls(box))
        let languages = menu.items.first { $0.title == "Язык распознавания" }?.submenu
        let russian = languages?.items.first { $0.title == "Русский" }
        box.language = .english
        DictationHUDMenuTarget.shared.pick(russian!)
        #expect(box.language == .russian)
    }

    @Test("пункт сворачивания называет действие по состоянию")
    func сворачиваниеНазываетДействие() {
        // «Свернуть» поверх уже свёрнутой плашки - обещание, которого пункт не
        // исполнит.
        let box = Box()
        #expect(makeDictationHUDMenu(controls: controls(box))
                    .items.map(\.title).contains("Свернуть плашку"))
        box.size = .small
        #expect(makeDictationHUDMenu(controls: controls(box))
                    .items.map(\.title).contains("Развернуть плашку"))
    }

    @Test("сворачивание переключает размер туда и обратно")
    func сворачиваниеПереключает() {
        let box = Box()
        let menu = makeDictationHUDMenu(controls: controls(box))
        let item = menu.items.first { $0.title.contains("вернуть плашку") }
        DictationHUDMenuTarget.shared.toggleSize()
        #expect(box.size == .small)
        DictationHUDMenuTarget.shared.toggleSize()
        // Развёрнутое состояние - средний, а не большой: большой владелец
        // выбирает сам и терять его на сворачивании он не просил.
        #expect(box.size == .medium)
        #expect(item != nil)
    }

    @Test("в меню короткий список, а не все языки распознавателя")
    func списокКороткий() {
        // Четырнадцать строк под курсором - это не выбор, а поиск.
        #expect(dictationHUDMenuLanguages.count == 3)
        #expect(dictationHUDMenuLanguages.first == .auto)
        #expect(DictationLanguage.allCases.count > dictationHUDMenuLanguages.count)
    }

    @Test("у каждого языка распознавателя есть имя в меню")
    func уКаждогоЯзыкаЕстьИмя() {
        // Список в меню короткий, но имя обязано быть у любого: язык может
        // прийти из настроек, и пункт без имени выглядел бы пустой строкой.
        for language in DictationLanguage.allCases {
            #expect(!dictationLanguageMenuTitle(language).isEmpty)
        }
    }
}
