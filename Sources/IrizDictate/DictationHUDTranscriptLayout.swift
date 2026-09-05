// Геометрия панели расшифровки: сколько места занимает не доехавший текст.
//
// Числа живут здесь, в чистых функциях под тестом, а не в рисующем коде. У
// геометрии плашки в этом проекте уже есть история из пяти отказов подряд, и
// разъехаться модели с картинкой нельзя.
import CoreGraphics
import Foundation

/// Ширина панели расшифровки: шире плашки, но не во весь экран.
public let DICTATION_HUD_TRANSCRIPT_WIDTH_SCALE: CGFloat = 2.6
/// Поле от кромки стекла до текста.
public let DICTATION_HUD_TRANSCRIPT_PADDING: CGFloat = 14
/// Сколько строк текста показываем целиком. Дальше панель не растёт, а текст
/// прокручивается: надиктовка на три минуты не имеет права занять весь экран.
public let DICTATION_HUD_TRANSCRIPT_MAX_LINES = 7
/// Высота строки в пунктах при кегле панели.
public let DICTATION_HUD_TRANSCRIPT_LINE_HEIGHT: CGFloat = 17
/// Кегль текста в панели.
public let DICTATION_HUD_TRANSCRIPT_FONT_SIZE: CGFloat = 13
/// Поле от кромки непрозрачной подложки до текста.
public let DICTATION_HUD_TRANSCRIPT_CARD_INSET: CGFloat = 10
/// Скругление непрозрачной подложки.
public let DICTATION_HUD_TRANSCRIPT_CARD_RADIUS: CGFloat = 12
/// Высота строки с кнопкой «Скопировать».
public let DICTATION_HUD_TRANSCRIPT_FOOTER_HEIGHT: CGFloat = 22
/// Просвет между подложкой с текстом и кнопкой.
public let DICTATION_HUD_TRANSCRIPT_FOOTER_GAP: CGFloat = 8
/// Сколько длится раскрытие плашки в панель. Столько же, сколько морф стекла:
/// это одно движение, и разъехаться его части не имеют права.
public let DICTATION_HUD_TRANSCRIPT_MORPH_SECONDS: TimeInterval = 0.34
/// Сколько держится подтверждение «Скопировано» перед тем, как панель уйдёт.
public let DICTATION_HUD_TRANSCRIPT_COPIED_SECONDS: TimeInterval = 0.5
/// Подпись кнопки и её подтверждение.
public let DICTATION_HUD_TRANSCRIPT_COPY_TITLE = "Скопировать"
public let DICTATION_HUD_TRANSCRIPT_COPIED_TITLE = "Скопировано"

/// Размер окна под панель расшифровки.
///
/// Ширина берётся от размера плашки, который выбрал владелец: панель обязана
/// быть шире плашки, иначе текст в ней не помещается, но не шире экрана.
/// Высота растёт по числу строк и упирается в потолок.
public func dictationHUDTranscriptSize(lineCount: Int,
                                       plateSize: CGSize,
                                       screenWidth: CGFloat) -> CGSize {
    let wanted = plateSize.width * DICTATION_HUD_TRANSCRIPT_WIDTH_SCALE
    let width = min(max(plateSize.width, wanted), max(plateSize.width, screenWidth - 80))
    let lines = min(max(1, lineCount), DICTATION_HUD_TRANSCRIPT_MAX_LINES)
    let textHeight = CGFloat(lines) * DICTATION_HUD_TRANSCRIPT_LINE_HEIGHT
    // Считаем то, что реально стоит в панели сверху вниз: поле, подложка с
    // текстом, просвет, строка с кнопкой, поле. Раньше высота считалась без
    // подложки и без кнопки, и текст упирался в кромку стекла.
    let height = DICTATION_HUD_TRANSCRIPT_PADDING * 2
        + DICTATION_HUD_TRANSCRIPT_CARD_INSET * 2
        + textHeight
        + DICTATION_HUD_TRANSCRIPT_FOOTER_GAP
        + DICTATION_HUD_TRANSCRIPT_FOOTER_HEIGHT
    return CGSize(width: width.rounded(), height: max(plateSize.height, height).rounded())
}

/// Сколько строк займёт текст при этой ширине. Оценка по средней ширине знака:
/// точный замер делает CoreText в самом виде, а модели нужна цифра, от которой
/// считается окно ДО того, как вид существует.
public func dictationHUDTranscriptLineCount(text: String, width: CGFloat) -> Int {
    // Текст живёт внутри подложки, а подложка - внутри поля панели. Считать
    // ширину по одному полю значит обещать строке больше места, чем у неё есть,
    // и панель окажется ниже текста: хвост обрежется.
    let usable = max(40, width
                     - DICTATION_HUD_TRANSCRIPT_PADDING * 2
                     - DICTATION_HUD_TRANSCRIPT_CARD_INSET * 2)
    let perLine = max(8, Int(usable / (DICTATION_HUD_TRANSCRIPT_FONT_SIZE * 0.52)))
    var lines = 0
    for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
        lines += max(1, Int(ceil(Double(paragraph.count) / Double(perLine))))
    }
    return max(1, lines)
}
