// Поле для первой диктовки.
//
// Первая диктовка обязана случиться в безопасном месте. Иначе она случается в
// чужом окне: человек ставит курсор в чей-то редактор и говорит туда, ещё не
// зная, что выйдет. Если выйдет мусор, мусор окажется в его работе.
//
// Поле не «демонстрация»: текст сюда попадает тем же путём, что и в любое
// другое поле, - приложение вставляет его в фокус. Значит проба честная, а не
// имитация, и если вставка не работает, человек узнает об этом здесь, а не
// потом.
//
// Три условия, без которых проба врёт, и все три были нарушены.
//   1. Поле обязано ДЕРЖАТЬ ФОКУС само. Вставка идёт туда, где мигает курсор, а
//      курсор не стоял нигде - текст уезжал в чужое окно, и владелец видел
//      «как будто идёт загрузка» и пустой экран.
//   2. Поле обязано быть ВИДНО. Рамка на слое самого NSScrollView не рисуется
//      вовсе: её перекрывает документ. Рамку рисует отдельная коробка.
//   3. Enter обязан вести ДАЛЬШЕ. Текстовый вид принимает перевод строки себе,
//      и человек, жмущий Enter, вместо следующего экрана набивал пустые строки
//      в поле пробы.
import AppKit
import SwiftUI

struct FirstRunDictationField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Что делать по Enter. Поле не знает про шаги знакомства, поэтому
    /// решение приходит замыканием.
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> FirstRunFieldBox {
        let textView = FirstRunTextView()
        textView.placeholder = placeholder
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 14)
        textView.isEditable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = CGSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let box = FirstRunFieldBox(frame: .zero)
        box.embed(scroll)
        return box
    }

    func updateNSView(_ box: FirstRunFieldBox, context: Context) {
        guard let textView = box.textView else { return }
        if textView.string != text { textView.string = text }
        textView.placeholder = placeholder
        context.coordinator.onSubmit = onSubmit
        // Курсор ставится в это поле и остаётся здесь: диктовка вставляет
        // текст туда, где он мигает.
        guard !context.coordinator.focused, let window = box.window else { return }
        context.coordinator.focused = true
        DispatchQueue.main.async { window.makeFirstResponder(textView) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var focused = false
        var onSubmit: (() -> Void)?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onSubmit?()
            return true
        }
    }
}

/// Коробка вокруг поля: плотная подложка и видимая рамка.
///
/// Рамка живёт здесь, а не на слое NSScrollView: там её закрывает документ, и
/// поле выглядит как пустое место посреди белого окна.
final class FirstRunFieldBox: NSView {
    private(set) var scroll: NSScrollView?
    var textView: FirstRunTextView? { scroll?.documentView as? FirstRunTextView }

    func embed(_ scroll: NSScrollView) {
        self.scroll = scroll
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            // Разделительный серый на белом окне не виден вовсе, а поле обязано
            // читаться как место, куда придёт текст.
            layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        }
    }
}

/// Поле с подсказкой внутри. Пустое поле без подписи молчит о том, зачем оно
/// тут стоит.
final class FirstRunTextView: NSTextView {
    var placeholder: String = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        (placeholder as NSString).draw(at: CGPoint(x: textContainerInset.width + 4,
                                                   y: textContainerInset.height),
                                       withAttributes: attributes)
    }
}
