// Шаг «скачаем распознавание»: кнопка, полоса хода и честная подпись.
//
// Ход показывается, потому что полгигабайта молча качать нельзя: человек,
// который не видит движения, через минуту решает, что зависло, и закрывает
// окно. Идти дальше при этом можно сразу - загрузка не держит знакомство.
import IrizDictate
import SwiftUI

struct FirstRunModelInstall: View {
    @ObservedObject var model: FirstRunModel

    var body: some View {
        VStack(spacing: 10) {
            if model.modelInstalled {
                Text(FirstRunCopy.modelReady)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if let phase = model.installPhase {
                switch phase {
                case .failed(let reason):
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button(FirstRunCopy.modelFailedRetry) { model.installModel() }
                        .modifier(FirstRunProminentButton())
                default:
                    Text(speechModelInstallTitle(phase))
                        .font(.system(size: 13, weight: .medium))
                    ProgressView(value: speechModelInstallFraction(phase))
                        .progressViewStyle(.linear)
                        .frame(width: 260)
                }
            } else {
                Text(FirstRunCopy.hintModel)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Button(FirstRunCopy.model.action ?? "") { model.installModel() }
                    .modifier(FirstRunProminentButton())
            }
        }
    }
}
