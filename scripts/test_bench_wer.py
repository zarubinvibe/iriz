#!/usr/bin/env python3
"""Проверка среза корпуса в bench_wer.py.

Срез обязан выводиться ИЗ ЭТАЛОНА, а не назначаться исполнителем: иначе
порог 44,05 на смешанной речи сравнивается с другим множеством записей.
Данные здесь синтетические - корпус владельца в репозиторий не попадает.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

WER = Path(__file__).with_name("bench_wer.py")
sys.path.insert(0, str(WER.parent))
from bench_wer import has_numeral, in_slice, measure  # noqa: E402


class SliceRuleTests(unittest.TestCase):
    def test_latin_in_reference_makes_it_mixed(self):
        self.assertTrue(in_slice("открой pull request сегодня", "mixed"))
        self.assertFalse(in_slice("открой pull request сегодня", "clean"))

    def test_pure_cyrillic_is_clean(self):
        self.assertTrue(in_slice("ходатайство об отложении", "clean"))
        self.assertFalse(in_slice("ходатайство об отложении", "mixed"))

    def test_all_takes_everything(self):
        for text in ("только кириллица", "с latin внутри", "123"):
            self.assertTrue(in_slice(text, "all"))

    def test_digits_alone_do_not_make_it_mixed(self):
        # Цифры есть в обоих языках: смешанной запись делает только латиница.
        self.assertTrue(in_slice("дело 2026 года", "clean"))


class MeasureSliceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ref = Path(self.tmp.name) / "ref"
        self.hyp = Path(self.tmp.name) / "hyp"
        self.ref.mkdir()
        self.hyp.mkdir()
        # 01 чистая и распознана верно; 02 смешанная и ошиблась целиком.
        (self.ref / "01.txt").write_text("суд отложил заседание", encoding="utf-8")
        (self.hyp / "01.txt").write_text("суд отложил заседание", encoding="utf-8")
        (self.ref / "02.txt").write_text("открой pull request", encoding="utf-8")
        (self.hyp / "02.txt").write_text("открой пул реквест", encoding="utf-8")

    def test_slices_split_the_same_directory(self):
        _, clean_err, clean_total = measure(self.ref, self.hyp, "clean")
        _, mixed_err, mixed_total = measure(self.ref, self.hyp, "mixed")
        _, all_err, all_total = measure(self.ref, self.hyp, "all")
        self.assertEqual((clean_err, clean_total), (0, 3))
        self.assertEqual((mixed_err, mixed_total), (2, 3))
        # Срезы не пересекаются и в сумме дают целое.
        self.assertEqual(clean_total + mixed_total, all_total)
        self.assertEqual(clean_err + mixed_err, all_err)

    def test_cli_reports_the_slice_it_used(self):
        out = subprocess.run(
            [sys.executable, str(WER), "--slice", "mixed", str(self.ref), str(self.hyp), "0"],
            capture_output=True, text=True, check=True,
        ).stdout
        self.assertIn("срез mixed", out)
        self.assertIn("записей 1", out)

    def test_unknown_slice_is_refused(self):
        done = subprocess.run(
            [sys.executable, str(WER), "--slice", "почти", str(self.ref), str(self.hyp)],
            capture_output=True, text=True,
        )
        self.assertEqual(done.returncode, 2)

    def test_positional_usage_still_works_without_the_flag(self):
        out = subprocess.run(
            [sys.executable, str(WER), str(self.ref), str(self.hyp), "0"],
            capture_output=True, text=True, check=True,
        ).stdout
        self.assertIn("срез all", out)


class NumeralFilterTests(unittest.TestCase):
    def test_digits_and_number_words_both_count(self):
        for text in ("сумма 487 600 рублей", "четыреста восемьдесят семь тысяч", "дело 2026 года",
                     "третьего февраля", "часть первая статьи"):
            self.assertTrue(has_numeral(text), text)

    def test_text_without_numerals_passes(self):
        for text in ("суд отложил заседание", "открой pull request", "ходатайство удовлетворено"):
            self.assertFalse(has_numeral(text), text)

    def test_drop_numerals_excludes_by_reference_not_hypothesis(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        ref, hyp = Path(tmp.name) / "r", Path(tmp.name) / "h"
        ref.mkdir(); hyp.mkdir()
        # Эталон словами, расшифровка цифрами: без фильтра запись даст ошибки,
        # с фильтром выпадет целиком, потому что числительное есть в ЭТАЛОНЕ.
        (ref / "01.txt").write_text("сумма четыреста рублей", encoding="utf-8")
        (hyp / "01.txt").write_text("сумма 400 рублей", encoding="utf-8")
        (ref / "02.txt").write_text("суд отложил заседание", encoding="utf-8")
        (hyp / "02.txt").write_text("суд отложил заседание", encoding="utf-8")
        _, errs_raw, total_raw = measure(ref, hyp, "all", False)
        _, errs_drop, total_drop = measure(ref, hyp, "all", True)
        self.assertEqual((errs_raw, total_raw), (1, 6))
        self.assertEqual((errs_drop, total_drop), (0, 3))


if __name__ == "__main__":
    unittest.main()
