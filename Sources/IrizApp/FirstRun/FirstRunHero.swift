// Главный элемент экрана: НАСТОЯЩАЯ часть продукта, а не рисунок про неё.
//
// Здесь были схемы, которые я рисовал вектором. Владелец назвал их плохими, и
// он прав: слабая графика хуже отсутствующей, потому что занимает главное
// место на экране и при этом ничего не объясняет.
//
// Настоящая плашка и настоящий знак строки меню объясняют сами. Они врать не
// могут по устройству: это те же классы, которые работают в продукте, и
// увиденное здесь совпадает с тем, что человек получит через минуту.
import AppKit
import IrizDictate
import SwiftUI

struct FirstRunHero: View {
    let step: FirstRunStep

    var body: some View {
        switch step {
        case .welcome, .tryIt:
            LivePlate()
        case .whereItLives:
            MenuBarStrip()
        default:
            // На разрешениях героя нет намеренно. Показывать там нечего: то,
            // о чём идёт речь, живёт в системном окне, а не у нас. Картинка
            // ради картинки отнимает внимание у текста, который в этот момент
            // и есть работа экрана.
            Color.clear
        }
    }
}

/// Живая плашка продукта. Тот же класс, что показывает запись.
private struct LivePlate: NSViewRepresentable {
    func makeNSView(context: Context) -> DictationHUDPreviewView {
        let view = DictationHUDPreviewView(frame: .zero)
        view.isAnimating = true
        return view
    }

    func updateNSView(_ view: DictationHUDPreviewView, context: Context) {
        view.sizeChoice = DictationSettings.shared.dictationHUDSize
        view.isAnimating = true
    }
}

/// Полоска строки меню со знаком продукта на своём месте.
///
/// Знак настоящий: рисует его тот же вектор, что и в строке меню. Полоска
/// нужна, чтобы знак читался НА МЕСТЕ, а не сам по себе: «наверху справа»
/// словами понятно хуже, чем одной картинкой.
private struct MenuBarStrip: View {
    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(0.06))
                .frame(height: 26)
            HStack(spacing: 14) {
                MarkImage()
                    .frame(width: 18, height: 18)
                Circle().fill(.primary.opacity(0.22)).frame(width: 4, height: 4)
                Circle().fill(.primary.opacity(0.22)).frame(width: 4, height: 4)
            }
            .padding(.trailing, 14)
        }
        .frame(maxWidth: 420)
    }
}

private struct MarkImage: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = IrizMark.statusImage(state: MarkState(mode: .fixing, alarm: .none))
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}
