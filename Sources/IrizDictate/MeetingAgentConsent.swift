import AppKit
import IrizCore
import IrizPrompt

public enum MeetingProcessingChoice {
    case cancel
    case localOnly
    case fill(CodexPromptGenerator)
}

/// Согласие ограничено текущей очередью/повтором и выбранной конфигурацией.
/// Переключатель очистки диктовки и прошлые разрешения здесь не читаются.
@MainActor
public enum MeetingAgentConsent {
    public static func request(adapter: PromptAgentAdapter, model: String,
                               executableURL: URL?) -> MeetingProcessingChoice {
        let alert = NSAlert()
        alert.messageText = L("meetingConsent.title", "Расшифровка и протокол встречи")
        let available = executableURL != nil && (!adapter.requiresModel || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let destination: String
        switch adapter.destination {
        case .localMachine:
            destination = L("meetingConsent.localDestination", "локальная модель по настройкам CLI; конфигурация CLI может направить запрос на другой сервер")
        case .openAI: destination = "OpenAI"
        case .anthropic: destination = "Anthropic"
        case .moonshot: destination = "Moonshot"
        case .unknown:
            destination = L("meetingConsent.unknownDestination", "адрес определяет выбранная программа")
        }
        alert.informativeText = L("meetingConsent.localStorage", "Распознавание звука выполняется на этом Mac. При обработке аудио, полный текст, DOCX и JSON сохранятся в архиве iriz.") + "\n\n"
            + Lf("meetingConsent.sendText", "Для заполнения участников, обсуждения, решений и поручений весь текст встречи будет передан агенту %@. Направление: %@. Модель: %@. Возможны расходы по тарифу агента. Аудиофайл ему не передаётся.", adapter.displayName, destination,
                 model.isEmpty ? L("meetingConsent.defaultModel", "по настройкам агента") : model) + "\n\n"
            + L("meetingConsent.draft", "Результат — черновик, его нужно сверить с записью. Без агента сохранятся расшифровка и форма с явно неустановленными сведениями.")
        alert.addButton(withTitle: L("meetingConsent.localOnly", "Только локальная расшифровка"))
        if adapter.promptDelivery == .argument {
            alert.informativeText += "\n\n" + L("meetingConsent.argvWarning", "Этот CLI принимает текст в аргументах: он будет виден другим процессам вашей учётной записи во время обработки.")
        }
        if available {
            alert.addButton(withTitle: L("meetingConsent.fill", "Передать текст и заполнить протокол"))
        } else {
            alert.informativeText += "\n\n" + L("meetingConsent.unavailable", "Агент не настроен: укажите CLI и модель в настройках «Промпт-режим». После этого протокол можно заполнить без повторного распознавания.")
        }
        alert.addButton(withTitle: L("meetingConsent.cancel", "Отмена")).keyEquivalent = "\u{1b}"
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { return .localOnly }
        if available, response == .alertSecondButtonReturn, let executableURL {
            return .fill(CodexPromptGenerator(executableURL: executableURL, adapter: adapter,
                                              model: model, timeoutSeconds: 300))
        }
        return .cancel
    }
}
