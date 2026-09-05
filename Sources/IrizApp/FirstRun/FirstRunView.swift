// Окно знакомства: одна мысль на экран, по центру, с картинкой и с пробой.
//
// Композиция по центру, а не по левому краю. Левое выравнивание годится
// длинному тексту, который читают строку за строкой; здесь на экране две-три
// фразы и картинка, и прижатые влево они выглядят анкетой, а не разговором.
//
// Кнопку, которую надо нажать, показываем ЯВНО: стрелка и подпись рядом.
// Владелец сказал прямо - разжёвывать. Человек в этот момент насторожен, у
// него на экране чужие системные окна, и догадываться, куда нажимать, ему
// нечем.
import AppKit
import SwiftUI

struct FirstRunView: View {
    @ObservedObject var model: FirstRunModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 48)

            footer
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
        }
        .frame(width: 640, height: 560)
        .background(FirstRunBackdrop())
    }

    private var step: FirstRunStep { model.step }
    private var isGranted: Bool {
        guard let permission = step.permission else { return false }
        return model.granted[permission] ?? false
    }

    private var content: some View {
        VStack(spacing: 16) {
            // Показываем НАСТОЯЩИЕ части продукта, а не рисунки про них.
            //
            // Схемы, которые тут были, рисовал я вектором - и владелец назвал
            // их плохими, справедливо. Слабая графика хуже её отсутствия: она
            // не объясняет и при этом занимает главное место на экране.
            // Настоящая плашка объясняет сама и врать не может по устройству.
            FirstRunHero(step: step)
                .frame(height: 96)

            Text(step.copy.title)
                .font(.system(size: 27, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(step.copy.body)
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.88))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)

            if let note = step.copy.note {
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430)
            }

            if step == .agent {
                FirstRunAgentConnect(model: model)
                    .padding(.top, 2)
            } else if step == .translate {
                FirstRunTranslateTrial(model: model)
                    .padding(.top, 2)
            } else if step == .model {
                FirstRunModelInstall(model: model)
                    .padding(.top, 2)
            } else if step == .tryIt {
                FirstRunKeyTrial(model: model)
                    .padding(.top, 2)
            } else if let action = step.copy.action {
                FirstRunCallToAction(title: action,
                                     hint: step.actionHint,
                                     granted: isGranted) {
                    model.performAction()
                }
                .padding(.top, 4)
            }
        }
        .id(step)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.canGoBack {
                Button(FirstRunCopy.back) { model.goBack() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            FirstRunProgress(step: step)
            Spacer()
            Button(model.isLastStep ? FirstRunCopy.done : FirstRunCopy.next) { model.goNext() }
                .modifier(FirstRunProminentButton())
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Кнопка, на которую надо нажать, и стрелка к ней.
///
/// Стрелка живая: она тихо покачивается, пока разрешение не выдано, и исчезает
/// вместе с подписью, как только выдано. Указатель, который остаётся висеть
/// над сделанным делом, начинает врать.
private struct FirstRunCallToAction: View {
    let title: String
    let hint: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            // Стрелка убрана: нарисованная от руки, она выглядела хуже, чем
            // ничего. Кнопку выделяет её собственный вес и подпись под ней,
            // а не указатель рядом.
            if !granted {
                Text(hint)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Button(granted ? FirstRunCopy.granted : title, action: action)
                .modifier(FirstRunProminentButton())
                .disabled(granted)
                .opacity(granted ? 0.65 : 1)
        }
    }
}

/// Подложка окна. Стекло здесь только по кромке: на семи экранах текста
/// полупрозрачная подложка поверх чужих окон превращает объяснение в кашу, и
/// читаемость важнее эффекта.
private struct FirstRunBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            Rectangle().fill(.background.opacity(0.35))
        }
        .ignoresSafeArea()
    }
}

/// Точки шагов: путь виден целиком одним взглядом, считать не надо.
private struct FirstRunProgress: View {
    let step: FirstRunStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(FirstRunStep.allCases, id: \.self) { item in
                // Место у точки ОДНО и то же на всех шагах. Раньше выбранная
                // была крупнее, и на первом же переключении весь ряд сдвигался
                // вправо: указатель прогресса не имеет права ездить сам.
                Circle()
                    .fill(item == step ? Color.primary.opacity(0.8) : Color.primary.opacity(0.18))
                    .frame(width: 6, height: 6)
                    .scaleEffect(item == step ? 1.25 : 1)
                    .frame(width: 10, height: 10)
                    .animation(.easeOut(duration: 0.18), value: step)
            }
        }
        .accessibilityHidden(true)
    }
}

struct FirstRunProminentButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent).controlSize(.large)
        } else {
            content.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}
