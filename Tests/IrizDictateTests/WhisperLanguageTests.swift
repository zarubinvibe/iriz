import Foundation
import Testing

@testable import IrizDictate

@Suite("автоопределение языка не превращается в английский")
struct WhisperLanguageTests {
    /// Поймано владельцем живьём: русская речь молча выходила английским
    /// текстом, и выглядело это переводом, которого он не просил. Причина не в
    /// модели: `whisper_full_default_params` подставляет язык «en», а мы при
    /// автоопределении не передавали НИЧЕГО - то есть соглашались на английский.
    @Test func autoIsPassedExplicitly() {
        #expect(DictationLanguage.auto.whisperCode == "auto",
                "автоопределение снова отдано на усмотрение библиотеки")
    }

    /// Выбранный язык уходит своим кодом.
    @Test func explicitLanguagesKeepTheirCodes() {
        #expect(DictationLanguage.russian.whisperCode == "ru")
        #expect(DictationLanguage.english.whisperCode == "en")
    }

    /// Ни один язык не остаётся без кода: пустая строка снова означала бы
    /// «решай сам», то есть английский.
    @Test func everyLanguageHasACode() {
        for language in DictationLanguage.allCases {
            #expect(!language.whisperCode.isEmpty, "\(language) без кода языка")
        }
    }
}
