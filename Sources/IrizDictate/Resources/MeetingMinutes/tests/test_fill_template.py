import json
import io
import sys
import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import fill_template


def data(**fields):
    return {"fields": fields, "blocks": {
        "participants": [{"participant_id": "P1", "participant_name": "А"}, {"participant_id": "P2", "participant_name": "Б"}],
        "topics": [], "decisions": [], "actions": [], "open_issues": [], "transcript_speakers": [],
        "transcript_utterances": [{"utterance_id": "U1", "utterance_text": "строка 1\nстрока 2"}, {"utterance_id": "U2", "utterance_text": "готово"}],
    }}


class FillerTests(unittest.TestCase):
    def test_parts_preserved_and_repeated_blocks(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "out.docx"
            with ZipFile(ROOT / "template.docx") as z: before = {n: z.read(n) for n in z.namelist() if n != "word/document.xml"}
            fill_template.fill(ROOT / "template.docx", data(meeting_id="M"), out)
            with ZipFile(out) as z:
                self.assertEqual(before, {n: z.read(n) for n in before})
                xml = z.read("word/document.xml").decode()
            self.assertEqual(xml.count("P1"), 1)
            self.assertEqual(xml.count("P2"), 1)
            self.assertEqual(xml.count("U1"), 1)
            self.assertIn("строка 2", xml)
            self.assertNotIn("{{", xml)

    def test_unknown_keys_and_bad_types_fail(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "x.docx"
            bad = data(unknown="x")
            with self.assertRaises(ValueError): fill_template.fill(ROOT / "template.docx", bad, out)
            bad = data(meeting_id="x"); bad["blocks"]["participants"] = "wrong"
            with self.assertRaises(ValueError): fill_template.fill(ROOT / "template.docx", bad, out)

    def test_output_cannot_overwrite_inputs_or_existing(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "x.docx"
            fill_template.fill(ROOT / "template.docx", data(), out)
            with self.assertRaises(FileExistsError): fill_template.fill(ROOT / "template.docx", data(), out)
            with self.assertRaises(ValueError): fill_template.fill(ROOT / "template.docx", data(), ROOT / "template.docx")


class RobustnessTests(unittest.TestCase):
    def test_split_token_preserves_surrounding_runs_and_newlines(self):
        w = fill_template.W
        p = ET.fromstring(f'''<w:p xmlns:w="{w}"><w:r><w:rPr><w:b/></w:rPr><w:t>До </w:t></w:r><w:r><w:t>{{{{meeting_</w:t></w:r><w:r><w:t>id}}}}</w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t> после</w:t></w:r></w:p>''')
        fill_template.replace_tokens(p, {"meeting_id": "  А\nБ  "})
        runs = p.findall("w:r", fill_template.NS)
        self.assertEqual(runs[0].find("w:t", fill_template.NS).text, "До ")
        self.assertIsNotNone(runs[0].find("w:rPr/w:b", fill_template.NS))
        self.assertEqual(runs[-1].find("w:t", fill_template.NS).text, " после")
        self.assertIsNotNone(runs[-1].find("w:rPr/w:i", fill_template.NS))
        self.assertEqual(len(p.findall(".//w:br", fill_template.NS)), 1)
        self.assertEqual(runs[1].find("w:t", fill_template.NS).get("{http://www.w3.org/XML/1998/namespace}space"), "preserve")

    def test_literal_tokens_in_values_are_not_replaced(self):
        payload = data(meeting_id="M", meeting_title="Текст {{meeting_id}}")
        payload["blocks"]["transcript_utterances"][0]["utterance_text"] = "Скажи {{meeting_id}} и {{utterance_id}}."
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "filled.docx"
            fill_template.fill(ROOT / "template.docx", payload, out)
            with ZipFile(out) as z:
                xml = z.read("word/document.xml").decode()
            self.assertIn("Текст {{meeting_id}}", xml)
            self.assertIn("Скажи {{meeting_id}} и {{utterance_id}}.", xml)

    def test_ignorable_namespace_prefixes_remain_declared(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "out.docx"
            fill_template.fill(ROOT / "template.docx", data(), out)
            with ZipFile(out) as z:
                raw = z.read("word/document.xml")
            prefixes = {prefix for _, (prefix, uri) in ET.iterparse(io.BytesIO(raw), events=["start-ns"])}
            root = ET.fromstring(raw)
            ignorable = root.get("{http://schemas.openxmlformats.org/markup-compatibility/2006}Ignorable", "")
            self.assertTrue(set(ignorable.split()).issubset(prefixes))

    def test_missing_internal_field_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            changed = Path(td) / "changed.docx"
            with ZipFile(ROOT / "template.docx") as source, ZipFile(changed, "w") as dest:
                for entry in source.infolist():
                    raw = source.read(entry.filename)
                    if entry.filename == "word/document.xml":
                        root = ET.fromstring(raw)
                        for p in root.findall(".//w:p", fill_template.NS):
                            if "participant_name" in "".join(p.itertext()):
                                for text in p.findall(".//w:t", fill_template.NS):
                                    text.text = "Удалено"
                        raw = ET.tostring(root)
                    dest.writestr(entry, raw)
            with self.assertRaises(ValueError):
                fill_template.fill(changed, data(), Path(td) / "out.docx")

    def test_invalid_xml_character_and_row_key_are_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "out.docx"
            with self.assertRaises(ValueError):
                fill_template.fill(ROOT / "template.docx", data(meeting_id="bad\x00"), out)
            bad = data()
            bad["blocks"]["participants"][0]["unknown"] = "x"
            with self.assertRaises(ValueError):
                fill_template.fill(ROOT / "template.docx", bad, out)


if __name__ == "__main__":
    unittest.main()
