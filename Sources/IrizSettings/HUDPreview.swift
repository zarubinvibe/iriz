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

    var body: some View {
        Button {
            selection = value
        } label: {
            VStack(spacing: 8) {
                HUDPreview(size: size, palette: palette, purpose: purpose, animates: isSelected)
                    .frame(width: dictationHUDCollapsedSize(size).width,
                           height: dictationHUDCollapsedSize(size).height)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
