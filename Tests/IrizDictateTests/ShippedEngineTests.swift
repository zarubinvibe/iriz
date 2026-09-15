import Foundation
import Testing

@testable import IrizDictate

@Suite("движок по умолчанию решается диском, а не константой")
struct ShippedEngineTests {
    /// В DMG нет модели. Встроенный установщик умеет поставить Parakeet. Если на
    /// диске есть только он, выбор отсутствующего Turbo оставит диктовку без
    /// движка. Поэтому решает диск, а не одна константа.
    @Test func installWithOnlyParakeetUsesIt() {
        let choice = SpeechModelProfile.installedDefault { $0 == .multilingualV3 }
        #expect(choice == .multilingualV3, "установка с одним Parakeet осталась без движка")
    }

    /// Владелец, установивший Turbo для русского и смешанной RU/EN техречи,
    /// получает именно его. Это проверка предпочтения, не качества модели.
    @Test func preferredEngineWinsWhenItIsInstalled() {
        let choice = SpeechModelProfile.installedDefault { _ in true }
        #expect(choice == SpeechModelProfile.productDefault)
        #expect(choice == .whisperTurbo)
    }

    /// На диске нет ничего. Выбираем профиль со встроенным установщиком, чтобы
    /// «модель не установлена» вело к рабочей кнопке загрузки.
    @Test func emptyDiskPointsAtTheEngineWithInstaller() {
        #expect(SpeechModelProfile.installedDefault { _ in false } == .multilingualV3)
    }

    /// Порядок падения назван явно: сначала профиль со встроенным установщиком.
    @Test func fallbackPrefersTheEngineWithInstaller() {
        let choice = SpeechModelProfile.installedDefault { $0 != .whisperTurbo }
        #expect(choice == .multilingualV3)
    }
}
