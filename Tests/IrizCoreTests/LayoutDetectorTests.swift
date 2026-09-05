import Testing
import IrizInput
@testable import IrizCore

// Тесты детектора раскладки и правки дефекта #23 (буквы б ю ж э х ъ ё на клавишах
// пунктуации: , . ; ' [ ] \). Русское слово, набранное в EN-раскладке, СОДЕРЖИТ
// пунктуацию: «бесит» → ",tcbn", «хорошо» → "[jhjij", «объект» → "j,]trn".
//
// Все вызовы идут через decide напрямую: typed — то, что набрал пользователь,
// converted — конвертация DynamicKeyMapping.convertAuto, т.е. ТА ЖЕ карта
// UCKeyTranslate, что в боевом пути приложения и CLI (единственная карта
// процесса; статических таблиц в коде нет — они молча расходились с реальной
// раскладкой машины, измеренный дефект: ё на клавише '\', а не '`').

/// Обёртка над decide: converted строится из typed боевой картой.
@MainActor
private func verdict(_ typed: String, current: String = "en", other: String = "ru",
                     capsLock: Bool = false) -> LayoutVerdict {
    LayoutDetector.decide(typed: typed, converted: DynamicKeyMapping.convertAuto(typed),
                          currentLang: current, otherLang: other, capsLock: capsLock)
}

/// Боевой путь целиком (зеркало AppDelegate.handleAutoConvert): сначала отщепление
/// хвостовой пунктуации, потом decide по ядру. Нужен для честного остатка — слов,
/// где буква из семёрки ПОСЛЕДНЯЯ: её EN-образ ("б"→",", "ю"→".", "ж"→";")
/// отщепляется как пунктуация, и ядро («k.,k» → «любл») словарём не подтверждается.
@MainActor
private func pipelineVerdict(_ typed: String) -> LayoutVerdict {
    let split = LayoutDetector.splitTrailingPunctuation(typed)
    let core = String(typed.prefix(split.coreLength))
    return LayoutDetector.decide(typed: core, converted: DynamicKeyMapping.convertAuto(core),
                                 currentLang: "en", otherLang: "ru", capsLock: false)
}

// MARK: - Позитивы EN→RU: каждая из семи букв в начале, середине и конце слова

// б (клавиша ",")
@MainActor @Test func detectsBesit_BAtStart() {
    #expect(verdict(",tcbn") == .switchToConverted)   // «бесит»
}
@MainActor @Test func detectsRabota_BInMiddle() {
    #expect(verdict("hf,jnf") == .switchToConverted)  // «работа»
}

// ю (клавиша ".")
@MainActor @Test func detectsYumor_YuAtStart() {
    #expect(verdict(".vjh") == .switchToConverted)    // «юмор»
}
@MainActor @Test func detectsKlyuch_YuInMiddle() {
    #expect(verdict("rk.x") == .switchToConverted)    // «ключ»
}

// ж (клавиша ";")
@MainActor @Test func detectsZhizn_ZhAtStart() {
    #expect(verdict(";bpym") == .switchToConverted)   // «жизнь»
}
@MainActor @Test func detectsMozhet_ZhInMiddle() {
    #expect(verdict("vj;tn") == .switchToConverted)   // «может»
}

// э (клавиша "'")
@MainActor @Test func detectsEto_EAtStart() {
    #expect(verdict("'nj") == .switchToConverted)     // «это»
}
@MainActor @Test func detectsPoezd_EInMiddle() {
    #expect(verdict("gjtpl") == .switchToConverted)   // «поезд»
}
@MainActor @Test func detectsKanoe_EAtEnd() {
    #expect(verdict("rfyj'") == .switchToConverted)   // «каноэ»
}

// х (клавиша "[")
@MainActor @Test func detectsHorosho_HAtStart() {
    #expect(verdict("[jhjij") == .switchToConverted)  // «хорошо»
}
@MainActor @Test func detectsPloho_HInMiddle() {
    #expect(verdict("gkj[j") == .switchToConverted)   // «плохо»
}
@MainActor @Test func detectsUspeh_HAtEnd() {
    #expect(verdict("ecgt[") == .switchToConverted)   // «успех»
}

// ъ (клавиша "]"). В современной орфографии ъ не бывает ни первой, ни последней
// буквой слова — только середина, поэтому позиций «начало/конец» у него нет.
@MainActor @Test func detectsObyekt_HardSignInMiddle() {
    #expect(verdict("j,]trn") == .switchToConverted)  // «объект»
}
@MainActor @Test func detectsPodiezd_HardSignInMiddle() {
    #expect(verdict("gjl]tpl") == .switchToConverted) // «подъезд»
}

// ё (клавиша "\"): замер UCKeyTranslate на com.apple.keylayout.Russian ЭТОЙ машины —
// ё сидит на обратном слэше. «Книжная» клавиша '`' здесь неверна: именно на этом
// расхождении статическая и динамическая карты разъехались, и случай «объём» из
// PR #23 в бою не работал при зелёных тестах. Значения ниже проверены боевым CLI.
@MainActor @Test func detectsYolka_YoAtStart() {
    #expect(verdict("\\krf") == .switchToConverted)   // «ёлка»
}
@MainActor @Test func detectsSchyot_YoInMiddle() {
    #expect(verdict("cx\\n") == .switchToConverted)   // «счёт»
}
@MainActor @Test func detectsEshyo_YoAtEnd() {
    #expect(verdict("to\\") == .switchToConverted)    // «ещё»
}
@MainActor @Test func detectsSvoyo_YoAtEnd() {
    #expect(verdict("cdj\\") == .switchToConverted)   // «своё»
}

// Заголовочный случай PR #23, второй слой: «объём» → "j,]\v" (на этой машине).
// NSSpellChecker токенизирует образ по пунктуации и читает его как «j» + «v» —
// обе одиночные буквы он считает словами. Без проверки «typed целиком из букв»
// гейт текущего языка вернул бы .keep. Здесь обязано быть .switchToConverted.
@MainActor @Test func detectsObyom_PRCase() {
    #expect(verdict("j,]\\v") == .switchToConverted)  // «объём»
}

// Дополнительные частотные слова из живого текста.
@MainActor @Test func detectsNuzhno() {
    #expect(verdict("ye;yj") == .switchToConverted)   // «нужно»
}
@MainActor @Test func detectsLyubit() {
    #expect(verdict("k.,bn") == .switchToConverted)   // «любит»
}

// Caps Lock: набранное капсом — не акроним, словарь зовём без учёта регистра.
@MainActor @Test func detectsCapsLockWord() {
    #expect(verdict(",TCBN", capsLock: true) == .switchToConverted)  // «БЕСИТ»
}

// MARK: - Позитивы RU→EN: английское слово, набранное в русской раскладке

@MainActor @Test func detectsHelloRuTyped() {
    #expect(verdict("руддщ", current: "ru", other: "en") == .switchToConverted)
}
@MainActor @Test func detectsComputerRuTyped() {
    #expect(verdict("сщьзгеук", current: "ru", other: "en") == .switchToConverted)
}
@MainActor @Test func detectsPrettyRuTyped() {
    #expect(verdict("зкуеен", current: "ru", other: "en") == .switchToConverted)
}

// MARK: - Короткие слова (2 буквы, частотный список ShortWords) и одна буква

@MainActor @Test func detectsTwoLetterNo() {
    #expect(verdict("yj") == .switchToConverted)      // «но» — частое ru-слово
}
@MainActor @Test func keepsTwoLetterGo() {
    #expect(verdict("go") == .keep)                   // частое en-слово
}
@MainActor @Test func keepsAmbiguousVs() {
    #expect(verdict("vs") == .keep)                   // в обоих списках — не трогаем
}
@MainActor @Test func undecidedTwoLetterUnknown() {
    #expect(verdict("ab") == .undecided)              // «фи» не в частотном списке
}
@MainActor @Test func undecidedSingleLetter() {
    #expect(verdict("z") == .undecided)               // 1 буква — не трогаем никогда
}

// MARK: - Негативы: порча запрещена (ожидание — НЕ switchToConverted)

@MainActor @Test func undecidedURL() {
    #expect(verdict("https://example.com") == .undecided)
}
@MainActor @Test func undecidedEmail() {
    #expect(verdict("user@example.com") == .undecided)
}
@MainActor @Test func undecidedPath() {
    #expect(verdict("/usr/bin") == .undecided)
}
@MainActor @Test func undecidedCamelCase() {
    #expect(verdict("getUserName") == .undecided)
}
@MainActor @Test func undecidedAllCapsHTTP() {
    #expect(verdict("HTTP") == .undecided)
}
@MainActor @Test func undecidedAllCapsOOO() {
    #expect(verdict("ООО") == .undecided)             // деловая фактура: форма юрлица
}
@MainActor @Test func undecidedArm64() {
    #expect(verdict("arm64") == .undecided)
}
@MainActor @Test func undecidedCaseNumber() {
    #expect(verdict("А00-12345/2026") == .undecided)  // деловая фактура: номер дела
}
@MainActor @Test func keepsGit() {
    #expect(verdict("git") == .keep)                  // «пше» не слово; «git» — слово en
}
@MainActor @Test func keepsNpm() {
    #expect(verdict("npm") == .keep)                  // «тзь» не слово
}
@MainActor @Test func keepsCurl() {
    #expect(verdict("curl") == .keep)                 // «сгкд» не слово
}
@MainActor @Test func keepsDont() {
    #expect(verdict("don't") == .keep)                // «вщтэе» не слово (случай из PR #23)
}
@MainActor @Test func keepsVkCom() {
    #expect(verdict("vk.com") == .keep)               // «млюсщь» не слово
}
@MainActor @Test func keepsCSVFragment() {
    #expect(verdict("a,b") == .keep)                  // «фби» не слово
}
@MainActor @Test func undecidedMixedScript() {
    #expect(verdict("приветworld") == .undecided)     // смесь алфавитов — код/идентификатор
}
@MainActor @Test func keepsAllCapsUnderCapsLock() {
    // Под Caps Lock вето акронимов снято; спасает словарь: «РЕЕЗ» не слово.
    #expect(verdict("HTTP", capsLock: true) == .keep)
}

// MARK: - Честный остаток: буква из семёрки — ПОСЛЕДНЯЯ в слове

// EN-образ такого слова кончается на "," / "." / ";" — боевой путь отщепляет их
// как хвостовую пунктуацию (issue #15), ядро («любл», «хле», «му») словарём не
// подтверждается, и авто-конверсия не происходит. Это граница метода, а не баг:
// ручной триггер конвертирует такие слова целиком. Зафиксировано как известное
// поведение — не «чинить» ослаблением проверок.
@MainActor @Test func remainderLyublyuEndsWithYu() {
    #expect(pipelineVerdict("k.,k.") == .keep)        // «люблю»: ядро «любл» не слово
}
@MainActor @Test func remainderHlebEndsWithB() {
    #expect(pipelineVerdict("[kt,") == .keep)         // «хлеб»: ядро «хле» не слово
}
@MainActor @Test func remainderMuzhEndsWithZh() {
    #expect(pipelineVerdict("ve;") == .undecided)     // «муж»: «му» не в частотном списке
}

// MARK: - Зафиксированное ложное срабатывание донора (НЕ из дефекта #23)

// «tls» → «еды», а «еды» — словарное русское слово, и «tls» нет в en-словаре.
// Детектор конвертирует. Это поведение донора существовало и ДО правки #23
// (старое вето «tls» пропускало: все символы — буквы). Класс решается списком
// исключений слов (AutoSwitchPolicy.isDeniedWord, этап 7), а не детектором.
// Тест фиксирует поведение как известное, чтобы регрессия/починка были видимы.
@MainActor @Test func knownFalsePositiveTls() {
    #expect(verdict("tls") == .switchToConverted)
}
