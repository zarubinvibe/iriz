// Основано на RuSwitcher (MIT, © 2025 Rashns), коммит 8c45253.
import Foundation

public enum LayoutVerdict { case switchToConverted, keep, undecided }

/// Решает, набрано ли слово в неправильной раскладке. Точность важнее полноты:
/// при любой неуверенности → .undecided (ничего не делаем). Ручной триггер остаётся.
///
/// Жёсткие гейты (secure/denied-app/never-convert/always-convert) проверяются
/// вызывающим кодом ДО decide — детектор про политику не знает.
public enum LayoutDetector {
    @MainActor
    public static func decide(typed: String, converted: String, currentLang: String, otherLang: String, capsLock: Bool) -> LayoutVerdict {
        // --- мягкие вето (дёшево, до словаря) ---
        // 1 буква — не трогаем никогда (неоднозначность запредельная). 2 буквы —
        // отдельная ветка ниже через частотный список (ShortWords), т.к. на такой длине
        // системный словарь ненадёжен; 3+ — обычный путь через NSSpellChecker.
        guard typed.count >= 2 else { return .undecided }
        // Дефект #23 (PR апстрима #23): в ЙЦУКЕН буквы б ю ж э х ъ ё сидят на клавишах
        // пунктуации , . ; ' [ ] ` — русское слово, набранное в EN, СОДЕРЖИТ пунктуацию:
        // «бесит» → ",tcbn", «объект» → "j,]trn". Вето «все символы набранного — буквы»
        // отбрасывало каждое пятое русское слово до словаря.
        // Символ допустим, если он буква ХОТЯ БЫ в одной из двух раскладок; цифры, @,
        // дефис — не-буквы по обе стороны, поэтому URL/почта/код/версии отсекаются как
        // раньше. Точность держит словарь, а не это вето. Разная длина сторон (слияние
        // графем) — консервативно .undecided, как «1 клавиша = 1 символ» у отщепления.
        guard typed.count == converted.count else { return .undecided }
        guard zip(typed, converted).allSatisfy({ $0.isLetter || $1.isLetter })
        else { return .undecided }                                         // цифры/URL/код/почта
        // Под Caps Lock весь текст в ВЕРХНЕМ регистре — это НЕ акроним и НЕ camelCase,
        // поэтому эти два вето применяем только когда Caps Lock выключен.
        if !capsLock {
            if isAllCaps(typed) { return .undecided }                      // акронимы
            if looksLikeCodeIdentifier(typed) { return .undecided }        // camelCase / смешанные алфавиты
        }

        let cur = String(currentLang.prefix(2))
        let oth = String(otherLang.prefix(2))

        // --- Короткие (2-буквенные) слова: позитивный частотный сигнал (3.1, issue #22) ---
        // NSSpellChecker на длине 2 принимает почти любой набор букв за «слово», поэтому
        // обычная двусторонняя проверка тут ненадёжна (ради этого и стоял гейт count>=3).
        // Вместо словаря — компактный список ЧАСТЫХ коротких слов (ShortWords), строго как
        // позитивный сигнал: конвертим 2 буквы ТОЛЬКО если конверсия — частое слово целевого
        // языка, а набранное — не частое слово текущего. Коллизий «частое↔частое» нет
        // (аудит образов раскладки). Пары с языком без списка сюда не попадают →
        // 2-буквенные, как и раньше, не трогаются.
        if typed.count == 2 {
            guard let othShort = ShortWords.common(oth) else { return .undecided }
            if let curShort = ShortWords.common(cur), curShort.contains(typed.lowercased()) {
                return .keep   // уже частое слово в текущей раскладке — не трогаем
            }
            return othShort.contains(converted.lowercased()) ? .switchToConverted : .undecided
        }

        // Словарь — без учёта регистра (Caps Lock не должен мешать определению слова).
        // Второй слой правки #23 живёт в Dict.isValidWord: она возвращает false для
        // строки не целиком из букв, поэтому гейт текущего языка ниже не читает
        // «j,]`v» как «j»+«v» (одиночные латинские буквы NSSpellChecker считает
        // словами) и не блокирует конверсию «объёма».
        guard Dict.isAvailable(oth) else { return .undecided }
        guard Dict.isValidWord(converted.lowercased(), lang: oth) else { return .keep }
        if Dict.isAvailable(cur), Dict.isValidWord(typed.lowercased(), lang: cur) {
            return .keep
        }
        return .switchToConverted
    }

    /// issue #15: отщепляет прилипшую к концу слова пунктуацию ("ghbdtn," → ядро 6 + ",").
    /// Ядро детектится и конвертится как обычно, хвост возвращается в поле ЛИТЕРАЛОМ —
    /// конвертировать его по кейкодам нельзя: клавиша ',' в EN — это 'б' в RU, а
    /// запятая RU (Shift+6) в EN — '^'. Набор консервативный: цифры, дефис, @/#
    /// НЕ отщепляем — для URL/кода/почты вето детектора отрабатывает по делу.
    /// Кавычки ' и " исключены сознательно: смарт-пунктуация приложений подменяет их
    /// типографскими, а на dead-key раскладках (U.S. International) апостроф — dead key;
    /// оба случая ломают счёт/литеральность. «…»/«»/– недостижимы из буфера (Option-слой).
    /// ВАЖНО: '.', ',', ';', ':' в EN — клавиши букв ю/б/ж/Ж в ЙЦУКЕН, поэтому вызывающий
    /// ОБЯЗАН проверить полную конверсию по словарю (неоднозначность «думаю» vs «дума.»).
    public static func splitTrailingPunctuation(_ s: String) -> (coreLength: Int, suffix: String) {
        let punct: Set<Character> = [",", ".", "!", "?", ";", ":", ")"]
        var core = s[...]
        while let last = core.last, punct.contains(last) { core = core.dropLast() }
        return (core.count, String(s.dropFirst(core.count)))
    }

    private static func isAllCaps(_ s: String) -> Bool {
        s == s.uppercased() && s != s.lowercased()
    }

    /// Похоже на программный идентификатор: внутренняя заглавная (camelCase/PascalCase)
    /// или смешение латиницы и кириллицы в одном токене → почти всегда код, не слово.
    private static func looksLikeCodeIdentifier(_ s: String) -> Bool {
        for (i, c) in s.enumerated() where i > 0 && c.isUppercase { return true }
        var hasLatin = false, hasCyrillic = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0x41...0x5A, 0x61...0x7A: hasLatin = true
            case 0x0400...0x04FF: hasCyrillic = true
            default: break
            }
        }
        return hasLatin && hasCyrillic
    }
}
