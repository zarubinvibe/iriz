import IrizCore
// Живая плашка внутри настроек: мост из AppKit в SwiftUI.
//
// Первый NSViewRepresentable в проекте, и заведён он по делу. Владелец просит
// выбирать размер и цвет КЛИКОМ ПО ВИЗУАЛУ, а не из списка слов. Показать
// «как будет выглядеть» можно двумя способами: нарисовать похожее на SwiftUI
// или показать настоящее. Похожее - это вторая копия внешнего вида, а такие
// копии в этом проекте уже четыре раза расходились с оригиналом.
import AppKit
import IrizDictate
import SwiftUI

/// Живая плашка. Рисуют те же классы, что рисуют настоящую.
struct HUDPreview: NSViewRepresentable {
    var size: DictationHUDSizeChoice
    var palette: DictationHUDWavePalette
    var purpose: DictationHUDPreviewPurpose = .dictation
    var animates: Bool

    func makeNSView(context: Context) -> DictationHUDPreviewView {
        let view = DictationHUDPreviewView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: DictationHUDPreviewView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: DictationHUDPreviewView) {
        view.sizeChoice = size
        view.palette = palette
        view.purpose = purpose
        view.isAnimating = animates
    }
}

/// Кнопка-визуал: живая плашка, по которой кликают. Выбранная обведена
/// акцентом семьи и живёт волной; остальные стоят - три бегущие волны рядом
/// спорят за внимание и мешают выбрать.
struct HUDPreviewChoice<Value: Equatable>: View {
    let value: Value
    @Binding var selection: Value
    let title: String
    let size: DictationHUDSizeChoice
    let palette: DictationHUDWavePalette
    var purpose: DictationHUDPreviewPurpose = .dictation

    private var isSelected: Bool { selection == value }

    @Namespace private var hudChoice

    var body: some View {
        Button {
            selection = value
        } label: {
            VStack(spacing: 8) {
                // Плашка стоит на ПЛИТЕ, как текст рядом.
                //
                // Стекло самой плашки прозрачное - решение владельца 06.09.2026,
                // и в жизни оно правильное: плашка висит поверх чужого окна, и
                // сквозь неё видно работу. Но здесь под ней не чужое окно, а
                // стекло НАШЕГО окна, и прозрачное на прозрачном не читается
                // вовсе. Слова владельца: «должна быть плашка такая же, как и
                // под текстом, а она очень прозрачная, я ничего не понимаю».
                //
                // Плотность даёт подложка, а не подмена стекла: подменить стиль
                // значило бы показывать в настройках не то, что владелец увидит
                // на экране.
                HUDPreview(size: size, palette: palette, purpose: purpose, animates: isSelected)
                    .frame(width: dictationHUDCollapsedSize(size).width,
                           height: dictationHUDCollapsedSize(size).height)
                    .padding(6)
                    .background(IrizFloatingPlate())
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.primary : IRIZ_SUBTLE)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: IRIZ_SELECTION_RADIUS,
                                           style: .continuous))
            // Обводка акцентом радиусом 14 была третьим способом подсветки в
            // продукте. Канон один: тонированное стекло, которое переезжает.
            .irizSelected(isSelected, in: hudChoice, group: "hud-preview")
        }
        .buttonStyle(IrizPressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
