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
