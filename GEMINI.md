# Agent Instructions

The rules for this repository live in [AGENTS.md](AGENTS.md). Read that file first, follow it exactly, and do not duplicate its rules here.

New to this house? Start the conversation from `docs/ONBOARDING-CHAT.md` — the agent walks the install step by step and names the price of each step. Russian and Chinese versions sit next to it: `docs/ONBOARDING-CHAT.ru.md`, `docs/ONBOARDING-CHAT.zh.md`.

## Knowledge graph

The house carries a built graph: `graphify-out/graph.json` and `graphify-out/GRAPH_REPORT.md`. That is free memory about the project — who calls whom, what lives where, which module leans on what. Start your search there instead of reading the whole tree: `graphify query "<question>"` answers faster and cheaper. Rebuild after changes with `graphify update .`
