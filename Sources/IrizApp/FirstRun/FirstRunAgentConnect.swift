// Шаг «подключить агента»: показать то, что уже стоит на этом Маке.
//
// Спрашивать путь к программе на экране знакомства нельзя: человек пришёл за
// простотой, а получил бы терминал. Поэтому агенты ищутся на диске, а список -
// это результат поиска, а не форма для заполнения.
//
// Ничего не выбрать - нормальный исход. Диктовка и раскладка работают без
// агента, и шаг об этом говорит прямо, а не намекает.
import SwiftUI

struct FirstRunAgentConnect: View {
    @ObservedObject var model: FirstRunModel

    var body: some View {
        VStack(spacing: 10) {
            if model.agents.isEmpty {
                Text(FirstRunCopy.agentNotFound)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            } else {
                // Список прокручивается, а не растёт: агентов может быть
                // сколько угодно, а высота окна фиксирована, и четвёртая
                // строка уже наезжала на кнопку «Дальше».
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(model.agents) { agent in
                            AgentRow(agent: agent,
                                     connected: model.connectedAgentID == agent.id) {
                                model.connectAgent(agent.id)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 150)
            }
        }
        .onAppear { model.refreshAgents() }
    }
}

private struct AgentRow: View {
    let agent: FirstRunAgent
    let connected: Bool
    let connect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 13, weight: .medium))
                // Путь виден: человек имеет право знать, какую именно программу
                // на его машине мы собираемся звать.
                Text(agent.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if connected {
                Text(FirstRunCopy.agentConnected)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Button(FirstRunCopy.agentConnect, action: connect)
                    .modifier(FirstRunTrialButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(0.05))
        }
        .frame(maxWidth: 440)
    }
}

struct FirstRunTrialButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
