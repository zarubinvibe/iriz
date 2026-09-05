import Testing
import IrizInput
@testable import IrizCore

@Test func keyMappingConvertsBothWays() {
    DynamicKeyMapping.configureSharedKeyMapping()
    #expect(KeyMapping.convert("ghbdtn") == "привет")
    #expect(KeyMapping.convert("привет") == "ghbdtn")
}

// Машинная правда: UCKeyTranslate на com.apple.keylayout.Russian ЭТОЙ машины даёт
// ё на клавише '\'. «Книжная» статическая таблица утверждала '`' — на этом
// расхождении двух карт тесты были зелёными при нерабочем бое (случай «объём»
// из PR #23). Тест краснеет, если карта снова собрана не из раскладки машины.
// Значения сверены боевым CLI: `printf 'объём' | smltlk convert` → "j,]\v".
@Test func keyMappingMatchesMachineLayout() {
    DynamicKeyMapping.configureSharedKeyMapping()
    #expect(KeyMapping.convert("ёлка") == "\\krf")
    #expect(KeyMapping.convert("\\krf") == "ёлка")
    #expect(KeyMapping.convert("объём") == "j,]\\v")
    #expect(KeyMapping.convert("j,]\\v") == "объём")
}

// Круговой прогон: слово в одну сторону и обратно обязано вернуться неизменным.
// Ловит одностороннюю поломку карты (символ есть в enToRu, но потерян в ruToEn).
@Test func keyMappingRoundtripsYoWords() {
    DynamicKeyMapping.configureSharedKeyMapping()
    for word in ["ёлка", "объём", "счёт", "своё", "ещё", "привет"] {
        #expect(KeyMapping.convert(KeyMapping.convert(word)) == word)
    }
}

@Test func splitTrailingPunctuationSeparatesCoreAndSuffix() {
    let split = LayoutDetector.splitTrailingPunctuation("ghbdtn,")
    #expect(split.coreLength == 6)
    #expect(split.suffix == ",")
    #expect(LayoutDetector.splitTrailingPunctuation("привет").suffix.isEmpty)
}
