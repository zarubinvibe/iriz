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
            if !model.modelIsReady {
                Text(model.isInstallingModel
                     ? L("firstrun.trialModelDownloading", "Модель ещё скачивается. Ход установки виден на её странице.")
                     : L("firstrun.trialModelMissing", "Модель ещё не установлена. Кнопка ниже вернёт к скачиванию."))
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button(L("firstrun.trialOpenModelSetup", "К установке модели")) { model.showModelSetup() }
                    .modifier(FirstRunProminentButton())
            } else if canHearKey {
                // Сама клавиша и есть кнопка замены. Строчка «Клавиша занята?
                // Поменять» снизу была незаметна: владелец 07.09.2026 сказал
                // прямо — «снизу не очень заметно… необходимо, чтобы вот та
                // большая плашка, где написано клавиша, была как рекордер,
                // чтобы можно было нажать на неё и заменить, и об этом
                // написать». Место, куда человек и так смотрит, работает лучше
                // подписи под ним.
                Button { model.changeHotkey() } label: {
                    KeyCap(label: model.hotkeyLabel, active: model.isRecording)
                        .frame(height: 58)
                }
                .buttonStyle(.plain)
                .help(FirstRunCopy.changeKeyHint)
                .accessibilityLabel(FirstRunCopy.changeKeyHint)

                Text(FirstRunCopy.changeKeyHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)

                // Пока идёт запись и разбор — НАСТОЯЩАЯ плашка, а не полоска
                // уровня и не крутилка.
                //
                // Владелец 07.09.2026: «когда появляется значок, точнее там типа
                // загрузки, этого не нужно. Нужно, чтобы вместо вот этих двух
                // элементов появлялась плашка, которая распознаёт текст. То есть
                // человек с этого момента должен понять, как это будет
                // выглядеть». Знакомство обязано показывать тот же предмет,
                // который встретит человека в работе, а не его заменитель.
                if model.isRecording || model.isTranscribing {
                    HUDPreview(size: .medium,
                               palette: DictationSettings.shared.dictationHUDWavePalette,
                               purpose: .dictation,
                               animates: true)
                        .frame(width: dictationHUDCollapsedSize(.medium).width,
                               height: dictationHUDCollapsedSize(.medium).height)
                        .transition(.opacity)
                        .animation(irizAnimation(.irizEaseOut), value: model.isRecording)
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

            if model.modelIsReady {
                FirstRunDictationField(text: $model.tryItText,
                                       placeholder: FirstRunCopy.trialFieldPlaceholder,
                                       onSubmit: { model.goNext() })
                    .frame(height: 68)
                    .frame(maxWidth: 440)
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
                    .fill(Color.accentColor)
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
                    .fill(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.16),
                                          lineWidth: active ? 2 : 1)
                    }
            }
            .offset(y: active ? 1 : 0)
            .animation(irizAnimation(.irizQuick), value: active)
            .accessibilityLabel(Lf("firstrun.dictationKey.a11y", "Клавиша диктовки: %@", label))
    }
}
