// Шаг «скажи по-русски, получи по-английски»: та же проба, что и с диктовкой,
// только другой клавишей.
//
// Проба идёт настоящим путём продукта: клавиша, речь, агент, вставка в поле.
// Показывать перевод как картинку было бы обманом - человек уйдёт с экрана,
// не узнав, работает ли это у него.
import IrizDictate
import IrizSettings
import SwiftUI

struct FirstRunTranslateTrial: View {
    @ObservedObject var model: FirstRunModel

    /// Перевод идёт через того же агента, что и задания. Без агента клавиша
    /// молчит, и сказать об этом надо здесь, а не оставить человека гадать.
    private var hasAgent: Bool { model.connectedAgentID != nil }

    var body: some View {
        VStack(spacing: 12) {
            if !hasAgent {
                Text(FirstRunCopy.translateNeedsAgent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Button(FirstRunCopy.trialBackToPermission) { model.goBack() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else if !model.translationEnabled {
                Button(FirstRunCopy.translateEnable) { model.enableTranslation() }
                    .modifier(FirstRunProminentButton())
            } else {
                KeyCapLabel(label: model.translationHotkeyLabel)
                Text(FirstRunCopy.translatePressKey)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            FirstRunDictationField(text: $model.translateText,
                                   placeholder: FirstRunCopy.translateFieldPlaceholder,
                                   onSubmit: { model.goNext() })
                .frame(height: 68)
                .frame(maxWidth: 440)
        }
        .onAppear { model.refreshTranslationHotkeyLabel() }
    }
}

/// Клавиша перевода тем же глифом, что печатает macOS. Отдельная от клавиши
/// диктовки: это разные жесты, и путать их нельзя.
private struct KeyCapLabel: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 17, weight: .medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                    }
            }
            .accessibilityLabel("Клавиша перевода: \(label)")
    }
}
