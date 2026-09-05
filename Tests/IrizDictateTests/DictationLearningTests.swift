// Проба обучения словаря из правок человека.
//
// Судится не «работает ли диффер», а два вопроса, на которые владелец имеет
// право получить ответ машиной:
//
//   1. Ловим ли мы правку расслышанного и НЕ ловим правку смысла. Словарь
//      применяется молча к каждой следующей диктовке, и мусорная пара будет
//      портить текст, пока её не заметят руками.
//   2. Не утекает ли чужой текст. Поле ввода принадлежит другому приложению;
//      наружу обязаны выходить только два слова, и никогда - содержимое поля.
import Foundation
import Testing

@testable import IrizDictate

@Suite("Обучение словаря из правок")
struct DictationLearningTests {
    @Test("правка расслышанного слова становится парой")
    func правкаРасслышанногоСтановитсяПарой() {
        let pairs = dictationLearnedPairs(
            inserted: "суд нещатно отклонил ходатайство",
            current: "суд нещадно отклонил ходатайство"
        )
        #expect(pairs == [DictationLearnedPair(heard: "нещатно", fixed: "нещадно")])
    }

    @Test("правка регистра тоже пара: аббревиатуры так и учат")
    func правкаРегистраТожеПара() {
        let pairs = dictationLearnedPairs(
            inserted: "запрос в омвд отправлен",
            current: "запрос в ОМВД отправлен"
        )
        #expect(pairs == [DictationLearnedPair(heard: "омвд", fixed: "ОМВД")])
    }

    @Test("замена смысла парой не становится")
    func заменаСмыслаНеПара() {
        // Человек передумал, а не поправил расслышанное. В словарь такое нельзя:
        // следующая диктовка со словом «понедельник» будет испорчена.
        let pairs = dictationLearnedPairs(
            inserted: "заседание в понедельник утром",
            current: "заседание во вторник утром"
        )
        #expect(pairs.isEmpty)
    }

    @Test("дописанные слова парой не становятся")
    func дописанноеНеПара() {
        let pairs = dictationLearnedPairs(
            inserted: "иск подан",
            current: "иск подан сегодня утром"
        )
        #expect(pairs.isEmpty)
    }

    @Test("удалённые слова парой не становятся")
    func удалённоеНеПара() {
        let pairs = dictationLearnedPairs(
            inserted: "иск подан сегодня утром",
            current: "иск подан"
        )
        #expect(pairs.isEmpty)
    }

    @Test("переписанная фраза парой не становится")
    func переписанноеНеПара() {
        // Три изменённых слова подряд означают, что человек передумал.
        let pairs = dictationLearnedPairs(
            inserted: "один два три четыре",
            current: "пять шесть семь четыре"
        )
        #expect(pairs.isEmpty)
    }

    @Test("короткое слово в словарь не идёт")
    func короткоеСловоНеИдёт() {
        // «дом» -> «том» правдоподобно как правка, но пара из трёх букв
        // применится к каждому такому слову в будущем и сломает текст.
        let pairs = dictationLearnedPairs(inserted: "он", current: "но")
        #expect(pairs.isEmpty)
    }

    @Test("чужой текст в поле не мешает и не попадает в пары")
    func чужойТекстНеМешает() {
        // Наш фрагмент стоит посреди чужого письма. Опоры - первое и последнее
        // слово вставки, окно строится по ним.
        let pairs = dictationLearnedPairs(
            inserted: "прошу приобщить документ",
            current: "Здравствуйте, Иван Петрович. прошу приобщить документик. С уважением."
        )
        #expect(pairs == [DictationLearnedPair(heard: "документ", fixed: "документик")])
    }

    @Test("пары не содержат ничего из чужого текста")
    func парыНеСодержатЧужогоТекста() {
        // Главная проба границы. Всё, что вокруг нашей вставки, - чужое, и его
        // не должно оказаться ни в одной паре ни одним словом.
        let secret = "пароль от сейфа 4815 и адрес Тверская 12"
        let pairs = dictationLearnedPairs(
            inserted: "прошу нещатно рассмотреть заявление",
            current: "\(secret) прошу нещадно рассмотреть заявление \(secret)"
        )
        #expect(pairs == [DictationLearnedPair(heard: "нещатно", fixed: "нещадно")])
        for pair in pairs {
            for word in dictationLearningWords(secret) {
                #expect(pair.heard != word)
                #expect(pair.fixed != word)
            }
        }
    }

    @Test("правка обоих краёв вставки окна не даёт")
    func правкаОбоихКраёвОкнаНеДаёт() {
        // Без нетронутой опоры мы не знаем, где кончается наш текст. Молчим,
        // а не гадаем.
        let pairs = dictationLearnedPairs(
            inserted: "первое среднее последнее",
            current: "правое среднее крайнее"
        )
        #expect(pairs.isEmpty)
    }

    @Test("текст без правок пар не даёт")
    func безПравокПарНет() {
        let text = "суд отклонил ходатайство"
        #expect(dictationLearnedPairs(inserted: text, current: text).isEmpty)
    }

    @Test("расстояние считается верно")
    func расстояниеВерно() {
        #expect(dictationLearningDistance(Array("нещатно"), Array("нещадно")) == 1)
        #expect(dictationLearningDistance(Array(""), Array("три")) == 3)
        #expect(dictationLearningDistance(Array("одно"), Array("одно")) == 0)
    }
}
