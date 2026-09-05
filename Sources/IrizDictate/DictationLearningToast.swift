// Всплывашка обучения: «было -> стало, добавить в словарь?».
//
// Форма снята с эталона, который показал владелец: пара слов, понятная кнопка,
// крестик с отсчётом времени. Отсчёт важен не как украшение - он обещает, что
// окно исчезнет само, и поэтому его можно не трогать.
//
// Поверхность канона: та же плита, что в настройках и в истории. Своего вида у
// всплывашки нет, иначе продукт снова разъедется на четыре стиля.
import AppKit
import IrizCore
import SwiftUI

/// Сколько живёт всплывашка. Меньше - человек не успеет прочитать пару,
/// больше - она превращается в мусор на экране.
let dictationLearningToastSeconds: TimeInterval = 14

@MainActor
final class DictationLearningToastPresenter {
    private var panel: NSPanel?
    /// Что делать с принятыми парами. Хранение - не дело всплывашки.
    var onAccept: ([DictationLearnedPair]) -> Void = { _ in }

    func show(_ pairs: [DictationLearnedPair]) {
        guard !pairs.isEmpty else { return }
        dismiss()

        let view = DictationLearningToastView(
            pairs: pairs,
            onAccept: { [weak self] in
                self?.onAccept(pairs)
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )

        // `.fixedSize()` обязателен: без него hosting меряет вид до раскладки
        // текста, ширина выходит меньше нужной, и обе подписи обрезаются
        // многоточием. Поймано первым же кадром.
        let hosting = NSHostingView(rootView: view.fixedSize())
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.setFrameOrigin(Self.origin(for: size))
        panel.orderFrontRegardless()
        self.panel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + dictationLearningToastSeconds) { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Внизу по центру того экрана, где курсор: там же, где человек только что
    /// работал, и там же, где он привык видеть плашку диктовки.
    private static func origin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 120)
    }
}

struct DictationLearningToastView: View {
    let pairs: [DictationLearnedPair]
    let onAccept: () -> Void
    let onDismiss: () -> Void

    @State private var remaining: Double = 1

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Поправили после вставки")
                    .font(.system(size: 11))
                    .foregroundStyle(IRIZ_SUBTLE)
                ForEach(pairs, id: \.heard) { pair in
                    HStack(spacing: 8) {
                        Text(pair.heard)
                            .strikethrough()
                            .foregroundStyle(IRIZ_SUBTLE)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(IRIZ_SUBTLE)
                        Text(pair.fixed)
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 13))
                }
            }

            // Один стиль кнопки, а не два: второй `.buttonStyle` подряд
            // отменяет первый, и стекло терялось молча. Отклик на нажатие у
            // стеклянного стиля свой, системный.
            Button("Запомнить", action: onAccept)
                .modifier(IrizGlassPill())

            DictationLearningToastClose(remaining: remaining, action: onDismiss)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(IrizFloatingPlate())
        .onAppear {
            // Отсчёт линейный: это ход времени, а не движение вещи, и любая
            // кривая здесь врала бы про оставшийся срок.
            withAnimation(.linear(duration: dictationLearningToastSeconds)) { remaining = 0 }
        }
    }
}

/// Крестик с дугой отсчёта. Дуга показывает, сколько осталось: окно закроется
/// само, и это видно, а не обещано.
struct DictationLearningToastClose: View {
    let remaining: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(IRIZ_SUBTLE.opacity(0.35), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: remaining)
                    .stroke(IRIZ_SUBTLE, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(IrizPressStyle())
        .accessibilityLabel("Закрыть")
    }
}

/// Кнопка-таблетка на стекле. Отдельным модификатором, потому что откат ниже
/// macOS 26 нужен и здесь.
struct IrizGlassPill: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}


/// Показ всплывашки на образцовой паре: для съёмки и для судейства вида.
///
/// Живёт рядом с самой всплывашкой, а не в приложении: демонстрация обязана
/// строить ТУ ЖЕ поверхность, что и продукт, иначе прибор снимет не то окно -
/// эту ошибку уже ловил разбор на окне настроек.
@MainActor
public func dictationLearningDemoToast() {
    let presenter = DictationLearningToastPresenter()
    demoToastHolder = presenter
    presenter.show([DictationLearnedPair(heard: "нещатно", fixed: "нещадно")])
}

/// Держатель на время показа: без ссылки презентер умрёт вместе с вызовом и
/// панель исчезнет в тот же кадр.
@MainActor
private var demoToastHolder: DictationLearningToastPresenter?
