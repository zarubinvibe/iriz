# Agent Instructions

The rules for this repository live in [AGENTS.md](AGENTS.md). Read that file first, follow it exactly, and do not duplicate its rules here.

Новичок в этом доме? Начните разговор по `docs/ONBOARDING-CHAT.ru.md` — агент проведёт установку шаг за шагом, называя цену каждого шага. Английская и китайская версии рядом: `docs/ONBOARDING-CHAT.md`, `docs/ONBOARDING-CHAT.zh.md`.

## Граф знаний

В доме лежит собранный граф: `graphify-out/graph.json` и `graphify-out/GRAPH_REPORT.md`. Это бесплатная память о проекте — кто кого зовёт, что где живёт, какой модуль на что опирается. Начинайте поиск с него, а не с чтения всего дерева подряд: `graphify query "<вопрос>"` отвечает быстрее и дешевле. Пересобрать после правок — `graphify update .`
