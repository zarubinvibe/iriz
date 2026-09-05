import Foundation
import Testing

@testable import IrizDictate

@Suite("движок по умолчанию решается диском, а не константой")
struct ShippedEngineTests {
    /// Найдено разбором путей пользователей 04.09.2026. Заводским стоял
    /// whisperTurbo, а образ кладёт только Parakeet: свежая установка искала на
    /// диске файл, которого нет, и не диктовала ВООБЩЕ - молча, без единого
    /// сообщения. Константа не годится ни в одну сторону, поэтому решает диск.
    @Test func freshInstallGetsTheEngineThatIsActuallyThere() {
        let choice = SpeechModelProfile.installedDefault { $0 == .multilingualV3 }
        #expect(choice == .multilingualV3, "свежая установка из образа осталась без движка")
    }

    /// А владелец, скачавший whisper ради терминов, получает именно его: замер
    /// показал, что Parakeet теряет его термины, и тихая подмена была бы
    /// ухудшением, которого никто не заметит.
    @Test func preferredEngineWinsWhenItIsInstalled() {
        let choice = SpeechModelProfile.installedDefault { _ in true }
        #expect(choice == SpeechModelProfile.productDefault)
        #expect(choice == .whisperTurbo)
    }

    /// На диске нет ничего: называем тот движок, который у человека и так есть
    /// в образе, чтобы «модель не установлена» вело к решаемой задаче.
    @Test func emptyDiskPointsAtTheEngineFromTheImage() {
        #expect(SpeechModelProfile.installedDefault { _ in false } == .multilingualV3)
    }

    /// Порядок падения назван явно и проверяется: сперва то, что в образе.
    @Test func fallbackPrefersTheShippedEngine() {
        let choice = SpeechModelProfile.installedDefault { $0 != .whisperTurbo }
        #expect(choice == .multilingualV3)
    }
}
