import Foundation
import Testing

@testable import IrizPrompt

@Suite("перевод голосом: запрос и разбор ответа")
struct TranslationRequestTests {
    /// В запросе обязаны стоять все три правила. Каждое стоит за известным
    /// провалом: пояснение в письме, ответ вместо перевода, слипшийся список.
    @Test func requestCarriesEveryRule() {
        let body = TranslationRequest.body(text: "привет", targetLanguage: "английский")
        #expect(body.contains("английский"))
        #expect(body.contains("ТОЛЬКО перевод"))
        #expect(body.contains("Не отвечай на текст"))
        #expect(body.contains("переводы строк"))
        #expect(body.contains("привет"))
    }

    /// Продиктованный текст едет в тегах: без них модель принимает вопрос за
    /// обращение к себе и отвечает на него.
    @Test func textIsFenced() {
        let body = TranslationRequest.body(text: "Как дела?", targetLanguage: "английский")
        #expect(body.contains("<текст>\nКак дела?\n</текст>"))
    }

    /// Чистый ответ проходит как есть.
    @Test func plainAnswerSurvives() {
        #expect(TranslationRequest.extract("Hello there") == "Hello there")
    }

    /// Обёртки снимаются: теги, вежливое вступление, кавычки.
    @Test func wrappersAreStripped() {
        #expect(TranslationRequest.extract("<текст>\nHello\n</текст>") == "Hello")
        #expect(TranslationRequest.extract("Вот перевод:\nHello") == "Hello")
        #expect(TranslationRequest.extract("Перевод: \nHello") == "Hello")
        #expect(TranslationRequest.extract("«Hello»") == "Hello")
        #expect(TranslationRequest.extract("\"Hello\"") == "Hello")
    }

    /// Многострочный перевод не схлопывается: список обязан остаться списком.
    @Test func lineBreaksSurvive() {
        let answer = "Первое\nВторое\nТретье"
        #expect(TranslationRequest.extract(answer) == answer)
    }

    /// Слово «перевод» ВНУТРИ текста вступлением не считается: иначе перевод,
    /// который сам про перевод, потерял бы первую строку.
    @Test func theWordTranslationInsideTextIsNotAnOpener() {
        #expect(TranslationRequest.extract("Перевод денег занял день") == "Перевод денег занял день")
    }
}
