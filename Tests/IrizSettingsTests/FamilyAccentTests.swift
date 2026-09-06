// Акцент семьи обязан быть ЧИТАЕМЫМ, а не просто семейным.
//
// Требование волны дословно: контраст и уменьшенная анимация проверяются в
// КАЖДОЙ теме. «Выглядит контрастно» - не мерило: числа считает WCAG.
import Foundation
import Testing

@testable import IrizSettings

@Suite("акцент семьи: контраст в обеих темах")
struct FamilyAccentTests {

    /// Порог для НЕтекстового элемента по WCAG 2.2 (1.4.11). Символ секции -
    /// графика: он несёт смысл, но текст секции рядом всё равно системный.
    private let graphicThreshold = 3.0

    @Test func акцентЧитаемВСветлойТеме() {
        for role in [FamilyAccentRole.personal, .flow] {
            let ratio = wcagContrastRatio(familyAccentComponents(role, dark: false),
                                          FamilySurface.light)
            #expect(ratio >= graphicThreshold,
                    "светлая тема, роль \(role): контраст \(ratio) ниже \(graphicThreshold)")
        }
    }

    @Test func акцентЧитаемВТёмнойТеме() {
        for role in [FamilyAccentRole.personal, .flow] {
            let ratio = wcagContrastRatio(familyAccentComponents(role, dark: true),
                                          FamilySurface.dark)
            #expect(ratio >= graphicThreshold,
                    "тёмная тема, роль \(role): контраст \(ratio) ниже \(graphicThreshold)")
        }
    }

    @Test func канонныеЗначенияНаБеломНЕЧитаемы_поэтомуИАдаптированы() {
        // Улика, ради которой светлая тема берёт другую светлоту: канонное
        // золото на белой форме даёт около 1,9:1. Если этот тест когда-нибудь
        // позеленеет наоборот, значит канон поменялся - и адаптацию надо
        // пересматривать, а не тащить дальше по инерции.
        let gold = wcagContrastRatio(FamilyPalette.gold, FamilySurface.light)
        let sky = wcagContrastRatio(FamilyPalette.sky, FamilySurface.light)
        #expect(gold < graphicThreshold, "канонное золото вдруг стало читаемым на белом: \(gold)")
        #expect(sky < graphicThreshold, "канонный голубой вдруг стал читаемым на белом: \(sky)")
    }

    @Test func цветНеЕдинственныйНосительСмысла() {
        // Первая редакция этого теста требовала, чтобы две роли различались по
        // ЯРКОСТИ, и покраснела: золото и голубой на рабочей светлоте дают
        // 1,05:1, то есть отличаются только тоном. Требование было выдумано
        // мной, а настоящее правило доступности другое: цвет не имеет права
        // быть единственным носителем смысла. У каждой секции свой символ и
        // своё имя, и вот это обязано быть уникальным.
        let symbols = SettingsSectionSpec.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count, "символы секций повторяются: \(symbols)")

        let titles = SettingsSectionSpec.allCases.map(\.title)
        #expect(Set(titles).count == titles.count, "имена секций повторяются: \(titles)")
    }

    @Test func акцентСекцийОдинНаВсех() {
        // Решение владельца 06.09.2026: «какие-то золотые, какие-то синие, это
        // странно, они должны быть одинаковые». Проба стережёт именно это -
        // второй цвет в заголовках секций не имеет права вернуться незаметно.
        let accents = Set(SettingsSectionSpec.allCases.map(\.accent))
        #expect(accents == [.personal], "в заголовках секций больше одного акцента: \(accents)")
    }

    @Test func формулаКонтрастаСчитаетИзвестныеЗначения() {
        // Проверка самого измерителя: чёрное на белом - ровно 21:1.
        let ratio = wcagContrastRatio((0, 0, 0), (1, 1, 1))
        #expect(abs(ratio - 21) < 0.01)
        #expect(abs(wcagContrastRatio((1, 1, 1), (1, 1, 1)) - 1) < 0.0001)
    }
}
