import IrizInput
import Testing

@Suite("Имена раскладок")
struct LayoutNamingTests {
    /// Меню написано по-русски; TIS отдаёт «Russian», потому что локализации
    /// у приложения нет. Два языка в одном меню — дефект, за который владелец
    /// забраковал вид 10.08.2026.
    @Test func knownLayoutsSpeakRussian() {
        #expect(LayoutNaming.russianName("Russian") == "Русская")
        #expect(LayoutNaming.russianName("Russian – PC") == "Русская — ПК")
        #expect(LayoutNaming.russianName("Ukrainian") == "Украинская")
    }

    /// Неизвестную раскладку не переводим: выдуманное имя хуже честного.
    /// «ABC» — имя собственное и остаётся собой.
    @Test func unknownLayoutsKeepTheirName() {
        #expect(LayoutNaming.russianName("ABC") == "ABC")
        #expect(LayoutNaming.russianName("Dvorak") == "Dvorak")
        #expect(LayoutNaming.russianName("") == "")
    }
}
