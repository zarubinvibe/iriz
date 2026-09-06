import IrizCore
// Проба настоящей клавишей: нажми ту клавишу, которой будешь пользоваться.
//
// Кнопка в окне пробу изображала, а не проводила. Человек уходил из знакомства,
// так и не узнав ЖЕСТА, ради которого всё затевалось, и первая настоящая
// диктовка снова была прыжком в неизвестность.
//
// Здесь на экране стоит сама клавиша, крупно и своим глифом. Её видно, её можно
// нажать не вставая, и её можно тут же поменять, если правый Command занят
// чужой программой. Смена делается ЗДЕСЬ, а не отправкой в настройки: человек,
// у которого клавиша занята, до настроек не дойдёт.
import AppKit
import IrizDictate
import IrizSettings
import SwiftUI

struct FirstRunKeyTrial: View {
    @ObservedObject var model: FirstRunModel

    /// Слышно ли клавишу вообще. Без разрешения на клавиши нажатие не доходит
    /// до приложения, и «нажми эту клавишу» становится ловушкой: человек жмёт,
    /// ничего не происходит, и он уходит с мыслью, что продукт сломан.
    private var canHearKey: Bool { model.granted[.inputMonitoring] ?? false }

    var body: some View {
        VStack(spacing: 12) {
            if canHearKey {
                KeyCap(label: model.hotkeyLabel, active: model.isRecording)
                    .frame(height: 58)

                if model.isRecording {
                    LevelBar(level: model.level)
                        .frame(width: 180, height: 4)
                }

                Text(statusLine)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.isRecording ? .primary : .secondary)
                    .animation(irizAnimation(.irizEaseOut), value: model.isRecording)

                if !model.isRecording, !model.isTranscribing, model.tryItText.isEmpty {
                    Text(FirstRunCopy.trialSample)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(FirstRunCopy.trialDeaf)
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(FirstRunCopy.trialBackToPermission) { model.goBack() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button(FirstRunCopy.trialFallback) { model.toggleTrial() }
                        .modifier(FirstRunTrialButton())
                }
            }

            FirstRunDictationField(text: $model.tryItText,
                                   placeholder: FirstRunCopy.trialFieldPlaceholder,
                                   onSubmit: { model.goNext() })
                .frame(height: 68)
                .frame(maxWidth: 440)

            if canHearKey {
                Button(FirstRunCopy.changeKey) { model.changeHotkey() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Что сказать под клавишей. Три состояния, и молчания среди них нет:
    /// после первого удачного текста человек обязан услышать, что получилось,
    /// иначе экран просто замирает.
    private var statusLine: String {
        if model.isRecording { return FirstRunCopy.trialListening }
        // Между «отпустил клавишу» и «текст на экране» есть пауза. Молчание в
        // ней читается поломкой, поэтому она названа.
        if model.isTranscribing { return FirstRunCopy.trialThinking }
        if !model.tryItText.isEmpty { return FirstRunCopy.trialDone }
        return FirstRunCopy.trialPressKey
    }
}

/// Уровень голоса. Локальное распознавание отдаёт текст с задержкой, и до его
/// появления человеку нужно видеть, что микрофон живой.
private struct LevelBar: View {
    let level: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule()
                    .fill(Color(nsColor: IRIZ_FAMILY_GOLD))
                    .frame(width: max(4, geometry.size.width * min(1, max(0, level))))
                    .animation(irizAnimation(.irizQuick), value: level)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FirstRunTrialButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Клавиша, нарисованная клавишей.
///
/// Не иллюстрация: это тот же глиф, которым macOS печатает модификаторы, в
/// прямоугольнике с толщиной. Человек ищет глазами ровно то, что у него под
/// пальцами. Пока идёт запись, клавиша «нажата»: тень уходит, фон темнеет.
private struct KeyCap: View {
    let label: String
    let active: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 17, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Color(nsColor: IRIZ_FAMILY_GOLD).opacity(0.18) : Color.primary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(active ? Color(nsColor: IRIZ_FAMILY_GOLD) : Color.primary.opacity(0.16),
                                          lineWidth: active ? 2 : 1)
                    }
            }
            .offset(y: active ? 1 : 0)
            .animation(irizAnimation(.irizQuick), value: active)
            .accessibilityLabel("Клавиша диктовки: \(label)")
    }
}
