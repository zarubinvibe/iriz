#!/usr/bin/env python3
"""Проба ворот против утечки: они обязаны краснеть от подсказки и молчать без нее."""
import sys
import tempfile
import unittest
from pathlib import Path

GATE = Path(__file__).with_name("bench_leak_check.py")
sys.path.insert(0, str(GATE.parent))
from bench_leak_check import leaks, terms  # noqa: E402


class LeakGateTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.ref = Path(tmp.name)
        (self.ref / "01.txt").write_text("Поправь MCP сервер и сделай git rebase в ветке feature.", encoding="utf-8")
        (self.ref / "02.txt").write_text("Суд отложил заседание на неделю.", encoding="utf-8")

    def test_prompt_sharing_a_term_is_caught(self):
        found = leaks("Обсуждаем git rebase и force push.", self.ref)
        self.assertTrue(found)
        self.assertIn("01.txt", {name for name, _ in found})
        self.assertIn("rebase", {t for _, t in found})

    def test_prompt_with_other_terms_passes(self):
        self.assertEqual(leaks("Смотрю logs в Kubernetes, деплою через Docker.", self.ref), [])

    def test_function_words_are_not_leaks(self):
        # «and» встречается в любом английском тексте и утечкой не является.
        (self.ref / "03.txt").write_text("Open the terminal and run the migration.", encoding="utf-8")
        self.assertEqual(leaks("Discussing a plan and the schedule.", self.ref), [])
        self.assertNotIn("and", terms("Discussing a plan and the schedule."))

    def test_cyrillic_only_prompt_has_no_terms(self):
        self.assertEqual(terms("Совсем без латиницы, только кириллица."), set())

    def test_substring_does_not_count(self):
        # «feature» в эталоне не должно ловиться промтом со словом «feat».
        self.assertEqual(leaks("Пишу feat в сообщении коммита.", self.ref), [])


if __name__ == "__main__":
    unittest.main()
