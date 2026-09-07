import Foundation
import Testing

@testable import IrizCore

@Suite("Язык интерфейса: выбор человека старше языка системы")
struct LocalizationTests {
    /// Выбор руками не обсуждается: человек может держать macOS на английском и
    /// хотеть русский интерфейс. Системный язык в этом случае не спрашивают.
    @Test func choiceBeatsSystem() {
        #expect(irizResolvedLanguage(choice: .ru, systemPreferred: ["en-US"]) == .ru)
        #expect(irizResolvedLanguage(choice: .en, systemPreferred: ["ru-RU"]) == .en)
        #expect(irizResolvedLanguage(choice: .zh, systemPreferred: ["ru-RU"]) == .zh)
    }

    /// «Авто» идет по списку предпочтений системы, а не по одному первому коду:
    /// у человека с китайским первым и русским вторым обе строки настоящие.
    @Test func autoFollowsSystemOrder() {
        #expect(irizResolvedLanguage(choice: .auto, systemPreferred: ["ru-RU", "en-US"]) == .ru)
        #expect(irizResolvedLanguage(choice: .auto, systemPreferred: ["en-GB", "ru"]) == .en)
        #expect(irizResolvedLanguage(choice: .auto, systemPreferred: ["zh-Hans-CN"]) == .zh)
    }

    /// Язык, которого у нас нет, не роняет интерфейс в пустоту: продукт написан
    /// по-русски, и падать некуда, кроме оригинала.
    @Test func unknownSystemLanguageFallsBackToTheOriginal() {
        #expect(irizResolvedLanguage(choice: .auto, systemPreferred: ["fr-FR", "de-DE"]) == .ru)
        #expect(irizResolvedLanguage(choice: .auto, systemPreferred: []) == .ru)
    }

    /// Китайский у Apple зовется zh-Hans, и папка перевода обязана называться
    /// так же, иначе Bundle просто не найдет таблицу.
    @Test func chineseFolderMatchesApple() {
        #expect(IrizLanguage.zh.folder == "zh-Hans")
        #expect(IrizLanguage.auto.folder == "ru")
    }

    /// Имя языка написано на нем самом: человек, открывший список на чужом
    /// языке, ищет свой глазами, а не переводом.
    @Test func languagesNameThemselves() {
        #expect(IrizLanguage.en.ownName == "English")
        #expect(IrizLanguage.zh.ownName == "简体中文")
    }
}

@Suite("Подстановка в переводе")
struct LocalizationFormatTests {
    @Test("оригинал получает доводы, когда перевода нет")
    func originalTakesArguments() {
        setIrizLanguageChoice(.ru)
        #expect(Lf("нет.такого.ключа", "Пример %d", 2) == "Пример 2")
        #expect(Lf("нет.такого.ключа", "Найден: %@", "/usr/bin/codex") == "Найден: /usr/bin/codex")
    }

    @Test("порядок доводов задаётся переводом, а не кодом")
    func translationDecidesOrder() {
        // Ровно ради этого в образце разрешён номер довода: у языка свой порядок
        // частей, и код о нём знать не обязан.
        #expect(String(format: "%2$@ · %1$@", "один", "два") == "два · один")
    }
}
