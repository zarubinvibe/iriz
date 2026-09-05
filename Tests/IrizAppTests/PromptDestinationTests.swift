import Foundation
import Testing

@testable import IrizPrompt

@Suite("адресат данных берётся у агента, а не печатается константой")
struct PromptDestinationTests {
    /// В меню стояло «расшифровка уходит в OpenAI» намертво. Агентов пять, и
    /// строка врала для четырёх, включая локальный Ollama, у которого не
    /// уходит никуда ничего. Про чужие данные приложение не имеет права
    /// ошибаться даже в мелкой серой строке.
    @Test func everyAgentNamesItsOwnDestination() {
        var seen = Set<String>()
        for id in PromptAgentCatalog.identifiers {
            guard let adapter = PromptAgentCatalog.adapter(id: id) else { continue }
            let title = adapter.destination.title
            #expect(!title.isEmpty, "\(id): адресат без имени")
            seen.insert(title)
        }
        #expect(seen.count > 1, "все агенты назвали один адрес - это и была ошибка")
    }

    /// Локальный агент обязан говорить, что данные остаются на машине.
    @Test func localAgentSaysDataStays() {
        let local = PromptAgentCatalog.identifiers.compactMap { PromptAgentCatalog.adapter(id: $0) }
            .filter { $0.destination.isLocal }
        #expect(!local.isEmpty, "локального агента не стало - проверка потеряла смысл")
        for adapter in local {
            #expect(adapter.destination.title.contains("этом Маке"),
                    "локальный агент не сказал, что данные остаются здесь")
        }
    }
}
