// Масштаб раскадровки. Пять отказов ленты подряд стоили ровно того, что
// правило «приговор только с кадра 248 x 74» жило в прозе, а в коде стоял
// зашитый `pixelScale = 4`. Здесь оно под тестом.
import CoreGraphics
import Foundation
import Testing

@testable import IrizDictate

@Suite("раскадровка: натуральная величина")
struct DictationHUDExportScaleTests {

    @Test func натуральныйКадрРовно248на74() {
        #expect(dictationHUDExportNaturalPixelSize() == CGSize(width: 248, height: 74))
    }

    @Test func кадрПриговораНеУвеличиваетсяНикакимЗапросом() {
        for requested: CGFloat in [1, 2, 3, 4, 8] {
            #expect(dictationHUDExportPixelScale(frameName: "look-01-dictation-dark",
                                                 requested: requested)
                    == DICTATION_HUD_EXPORT_NATURAL_SCALE)
        }
    }

    @Test func кадрРазглядыванияБерётЗапрошенныйМасштаб() {
        #expect(dictationHUDExportPixelScale(frameName: "motion-01-reveal-20", requested: 4) == 4)
        #expect(dictationHUDExportPixelScale(frameName: "frame-000000", requested: 3) == 3)
    }

    @Test func масштабМеньшеЕдиницыПодтягиваетсяКЕдинице() {
        #expect(dictationHUDExportPixelScale(frameName: "motion-01-reveal-20", requested: 0) == 1)
        #expect(dictationHUDExportPixelScale(frameName: "motion-01-reveal-20", requested: -4) == 1)
    }

    @Test func поУмолчаниюРаскадровкаИдётВНатуральнуюВеличину() {
        #expect(DICTATION_HUD_EXPORT_NATURAL_SCALE == 2)
        #expect(DICTATION_HUD_VERDICT_FRAME_PREFIX == "look-")
    }
}
