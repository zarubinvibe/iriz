// Проба наблюдателя: когда спрашиваем поле и когда обязаны промолчать.
//
// Ядро сравнивает два текста, а здесь судится доверие: не спросили ли мы чужое
// приложение, не спросили ли дважды, не сравнили ли вставку с текстом, который
// человек с тех пор переписал.
import Foundation
import Testing

@testable import IrizDictate

@MainActor
@Suite("Наблюдатель за правкой")
struct DictationLearningWatcherTests {
    /// Счётчик обращений к полю: главная улика в пробах ниже. Нас интересует не
    /// только ответ, но и сам факт вопроса к чужому приложению.
    final class Focus {
        var answer: (text: String, pid: pid_t)?
        var asked = 0
        init(_ answer: (text: String, pid: pid_t)?) { self.answer = answer }
    }

    private func watcher(_ focus: Focus) -> DictationLearningWatcher {
        let w = DictationLearningWatcher(readFocusedText: {
            focus.asked += 1
            return focus.answer
        })
        return w
    }

    @Test("правка в том же окне даёт пару")
    func правкаВТомЖеОкнеДаётПару() {
        let focus = Focus(("суд нещадно отклонил", 42))
        let w = watcher(focus)
        var got: [DictationLearnedPair] = []
        w.onPairs = { got = $0 }
        w.remember(inserted: "суд нещатно отклонил", pid: 42)
        _ = w.check()
        #expect(got == [DictationLearnedPair(heard: "нещатно", fixed: "нещадно")])
    }

    @Test("чужое приложение не спрашиваем дважды и пар не даём")
    func чужоеПриложениеНеДаётПар() {
        // Фокус ушёл в другое приложение: наш текст туда не попадал, сравнивать
        // нечего, а читать чужое поле без повода нельзя.
        let focus = Focus(("совсем другой текст", 99))
        let w = watcher(focus)
        w.remember(inserted: "суд нещатно отклонил", pid: 42)
        let result = w.check()
        #expect(result == .failure(.focusMovedToAnotherApp))
    }

    @Test("без своей вставки поле не спрашиваем вовсе")
    func безВставкиПолеНеСпрашиваем() {
        // Главная проба границы: пока мы ничего не вставляли, у нас нет ни
        // одной причины заглядывать в чужое поле.
        let focus = Focus(("что-то личное в чужом окне", 42))
        let w = watcher(focus)
        let result = w.check()
        #expect(result == .failure(.nothingRemembered))
        #expect(focus.asked == 0)
    }

    @Test("после проверки вставка забывается")
    func послеПроверкиВставкаЗабывается() {
        // Одна правка не может быть предложена дважды, и второй раз поле не
        // спрашивается.
        let focus = Focus(("суд нещадно отклонил", 42))
        let w = watcher(focus)
        w.remember(inserted: "суд нещатно отклонил", pid: 42)
        _ = w.check()
        let second = w.check()
        #expect(second == .failure(.nothingRemembered))
        #expect(focus.asked == 1)
    }

    @Test("забыли по команде - поле не спрашиваем")
    func забылиПоКомандеПолеНеСпрашиваем() {
        let focus = Focus(("суд нещадно отклонил", 42))
        let w = watcher(focus)
        w.remember(inserted: "суд нещатно отклонил", pid: 42)
        w.forget()
        _ = w.check()
        #expect(focus.asked == 0)
    }

    @Test("просроченную вставку не сравниваем и поле не спрашиваем")
    func просроченнуюНеСравниваем() {
        // За три минуты человек мог переписать текст целиком; сравнение с ним
        // даст мусор, а вопрос к полю будет чтением без повода.
        let focus = Focus(("суд нещадно отклонил", 42))
        let w = watcher(focus)
        let long = Date().addingTimeInterval(-dictationLearningWindowSeconds - 1)
        w.remember(inserted: "суд нещатно отклонил", pid: 42, now: long)
        let result = w.check()
        #expect(result == .failure(.tooLate))
        #expect(focus.asked == 0)
    }

    @Test("нечитаемое поле - отказ по имени, а не молчание")
    func нечитаемоеПолеОтказПоИмени() {
        let focus = Focus(nil)
        let w = watcher(focus)
        w.remember(inserted: "суд нещатно отклонил", pid: 42)
        #expect(w.check() == .failure(.fieldUnreadable))
    }

    @Test("пустая вставка не запоминается")
    func пустаяВставкаНеЗапоминается() {
        let focus = Focus(("что угодно", 42))
        let w = watcher(focus)
        w.remember(inserted: "", pid: 42)
        _ = w.check()
        #expect(focus.asked == 0)
    }
}
