// Проба границы очистки: что уходит с машины и когда.
//
// Судится не качество очистки, а обещание владельцу: обычная диктовка наружу не
// уходит никогда, кроме режима, включённого его руками. Обещание, которое
// держится комментарием, не держится ничем.
import Foundation
import Testing

@testable import IrizDictate

@Suite("Границы очистки речи")
struct SpeechCleanupModeTests {
    @Test("наружу уходит только внешний режим")
    func наружуТолькоВнешний() {
        #expect(SpeechCleanupMode.off.sendsTextOutside == false)
        #expect(SpeechCleanupMode.local.sendsTextOutside == false)
        #expect(SpeechCleanupMode.external.sendsTextOutside)
    }

    @Test("предупреждение есть ровно там, где текст уходит")
    func предупреждениеТамГдеУходит() {
        // Предупреждение без повода приучает не читать предупреждения, а
        // отправка без предупреждения - это отправка втихую.
        for mode in SpeechCleanupMode.allCases {
            #expect((mode.warning != nil) == mode.sendsTextOutside)
        }
    }

    @Test("битая запись в настройках не выпускает текст наружу")
    func битаяЗаписьНеВыпускаетНаружу() {
        // Значение из будущей версии, из чужого профиля, из повреждённого
        // файла - падаем в закрытый режим, а не в самый полезный.
        #expect(SpeechCleanupMode(rawValue: "cloud-super") == nil)
        let defaults = UserDefaults(suiteName: "iriz.cleanup.test")!
        defaults.removePersistentDomain(forName: "iriz.cleanup.test")
        defaults.set("cloud-super", forKey: "speech_cleanup_mode_v1")
        let settings = DictationSettings(defaults: defaults)
        #expect(settings.speechCleanupMode == .local)
        #expect(settings.speechCleanupMode.sendsTextOutside == false)
    }

    @Test("умолчание не выпускает текст наружу")
    func умолчаниеНеВыпускаетНаружу() {
        let defaults = UserDefaults(suiteName: "iriz.cleanup.default")!
        defaults.removePersistentDomain(forName: "iriz.cleanup.default")
        let settings = DictationSettings(defaults: defaults)
        #expect(settings.speechCleanupMode == .local)
        #expect(settings.speechCleanupMode.sendsTextOutside == false)
    }
}
