#!/usr/bin/env python3
"""Заполнение фиксированного DOCX-шаблона средствами стандартной библиотеки."""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
from xml.etree import ElementTree as ET

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
NS = {"w": W}
TOKEN = re.compile(r"{{\s*([A-Za-z0-9_]+)\s*}}")
BLOCKS = {
    "participants": ("participant_id", "speaker_label"),
    "topics": ("topic_id", "related_decision_action_ids"),
    "decisions": ("decision_id", "decision_source"),
    "actions": ("action_id", "action_source"),
    "open_issues": ("open_issue", "clarification_due"),
    "transcript_speakers": ("transcript_speaker_label", "speaker_identification_basis"),
    "transcript_utterances": ("utterance_id", "utterance_text"),
}
FIELD_DEFAULTS = {"approval_status": "черновик"}
ROW_FIELDS = {
    "participants": {"participant_id", "participant_name", "participant_organization_role", "participant_meeting_role", "attendance", "participation_mode", "participation_period", "speaker_label"},
    "topics": {"topic_id", "topic_title", "topic_speaker", "topic_status", "discussion_summary", "proposals", "disagreements", "related_decision_action_ids"},
    "decisions": {"decision_id", "decision_topic_id", "decision_text", "decision_conditions", "decision_approved_by", "decision_reason", "decision_source"},
    "actions": {"action_id", "action_related_id", "action_text", "action_deliverable", "action_owner_id_name", "action_helpers", "action_due", "action_due_original", "action_dependencies", "action_reviewer", "action_status", "action_source"},
    "open_issues": {"open_issue", "clarification_needed", "clarification_owner", "clarification_due"},
    "transcript_speakers": {"transcript_speaker_label", "transcript_participant_id", "transcript_speaker_name", "speaker_identification_basis"},
    "transcript_utterances": {"utterance_id", "utterance_recording_file", "utterance_start", "utterance_end", "utterance_speaker", "utterance_text"},
}

def text_of(node):
    return "".join(node.itertext())

def tokens_in(node):
    return [m.group(1) for m in TOKEN.finditer(text_of(node))]

def text_nodes(p):
    return list(p.iter("{%s}t" % W))

def replace_tokens(p, values):
    """Replace once, right to left, keeping the surrounding runs and their styles."""
    nodes = text_nodes(p)
    offsets = []
    full = ""
    for node in nodes:
        offsets.append((len(full), len(full) + len(node.text or "")))
        full += node.text or ""
    for match in reversed(list(TOKEN.finditer(full))):
        first = next(i for i, (a, b) in enumerate(offsets) if a <= match.start() < b)
        last = next(i for i, (a, b) in enumerate(offsets) if a < match.end() <= b)
        prefix = (nodes[first].text or "")[:match.start() - offsets[first][0]]
        suffix = (nodes[last].text or "")[match.end() - offsets[last][0]:]
        value = values.get(match.group(1), "не указано")
        if first == last:
            nodes[first].text = prefix + value + suffix
        else:
            nodes[first].text = prefix + value
            for node in nodes[first + 1:last]:
                node.text = ""
            nodes[last].text = suffix
    parents = {child: parent for parent in p.iter() for child in parent}
    for node in nodes:
        value = node.text or ""
        if not value:
            continue
        node.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
        parts = value.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        node.text = parts[0]
        parent = parents[node]
        at = list(parent).index(node)
        for part in parts[1:]:
            at += 1
            parent.insert(at, ET.Element("{%s}br" % W))
            at += 1
            extra = ET.Element("{%s}t" % W)
            extra.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
            extra.text = part
            parent.insert(at, extra)

def replace_empty(p):
    ppr = p.find("{%s}pPr" % W)
    for child in list(p):
        if child is not ppr:
            p.remove(child)
    r = ET.SubElement(p, "{%s}r" % W)
    ET.SubElement(r, "{%s}t" % W).text = "не зафиксировано в предоставленных данных"

def validate_data(data, all_tokens):
    if not isinstance(data, dict) or set(data) != {"fields", "blocks"}:
        raise ValueError("JSON должен содержать только fields и blocks")
    if not isinstance(data["fields"], dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in data["fields"].items()):
        raise ValueError("fields должен быть object[str, str]")
    if not isinstance(data["blocks"], dict) or set(data["blocks"]) - set(BLOCKS):
        raise ValueError("blocks должен содержать только известные имена")
    for key, rows in data["blocks"].items():
        if not isinstance(rows, list) or any(not isinstance(r, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in r.items()) for r in rows):
            raise ValueError(f"{key} должен быть list[object[str, str]]")
        if any(set(r) - ROW_FIELDS[key] for r in rows):
            raise ValueError(f"чужое поле в блоке {key}")
    strings = list(data["fields"].values()) + [v for rows in data["blocks"].values() for row in rows for v in row.values()]
    if any(re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f\ud800-\udfff\ufffe\uffff]", v) for v in strings):
        raise ValueError("недопустимые для XML символы во входных данных")
    supplied = set(data["fields"])
    allowed = all_tokens - set().union(*ROW_FIELDS.values())
    if supplied - allowed:
        raise ValueError("чужой ключ в fields: " + ", ".join(sorted(supplied - allowed)))

def fill(template, data, output):
    if output.resolve() == Path(template).resolve():
        raise ValueError("output не должен совпадать с template")
    with ZipFile(template) as zin:
        raw = zin.read("word/document.xml")
        for prefix, uri in re.findall(rb'xmlns(?::([\w.-]+))?="([^"]+)"', raw):
            ET.register_namespace(prefix.decode(), uri.decode())
        original_namespaces = re.findall(rb'xmlns(?::([\w.-]+))?="([^"]+)"', raw)
        root = ET.fromstring(raw)
        body = root.find("w:body", NS)
        children = list(body)
        occurrences = {}
        for i, child in enumerate(children):
            for token in tokens_in(child):
                occurrences.setdefault(token, []).append(i)
        all_tokens = set(occurrences)
        expected_file = Path(__file__).resolve().parent.parent / "fields.json"
        expected = {f["name"] for f in json.loads(expected_file.read_text(encoding="utf-8"))["fields"]}
        if all_tokens != expected or any(len(v) != 1 for v in occurrences.values()):
            raise ValueError("поля шаблона изменены или повторяются; сверьте fields.json")
        validate_data(data, all_tokens)
        ranges = {}
        for name, (start, end) in BLOCKS.items():
            if start not in occurrences or end not in occurrences or len(occurrences[start]) != 1 or len(occurrences[end]) != 1:
                raise ValueError(f"неоднозначный или отсутствующий диапазон {name}")
            a, b = occurrences[start][0], occurrences[end][0]
            if a > b: raise ValueError(f"перепутан диапазон {name}")
            actual = set().union(*(set(tokens_in(node)) for node in children[a:b + 1]))
            if actual != ROW_FIELDS[name]:
                raise ValueError(f"изменен состав полей диапазона {name}")
            ranges[name] = (a, b)
        previous_end = -1
        for a, b in sorted(ranges.values()):
            if a <= previous_end:
                raise ValueError("диапазоны карточек пересекаются")
            previous_end = b
        # Fill only non-row paragraphs before cloning; inserted values are never rescanned.
        fields = {**FIELD_DEFAULTS, **data["fields"]}
        protected = {i for a, b in ranges.values() for i in range(a, b + 1)}
        for i, child in enumerate(body):
            if i not in protected: replace_tokens(child, fields)
        for name, (a, b) in sorted(ranges.items(), key=lambda x: x[1][0], reverse=True):
            template_nodes = children[a:b + 1]
            rows = data["blocks"].get(name, [])
            replacement = []
            for row in rows:
                replacement.extend(copy.deepcopy(template_nodes))
                for node in replacement[-len(template_nodes):]: replace_tokens(node, row)
            if not rows:
                node = copy.deepcopy(template_nodes[0]); replace_empty(node); replacement = [node]
            body[:] = children[:a] + replacement + children[b + 1:]
            children = list(body)
        xml = ET.tostring(root, encoding="utf-8", xml_declaration=True)
        # Keep declarations used by lexical OOXML attributes such as mc:Ignorable.
        opening = re.search(rb"<(?!\?)[^>]+>", xml)
        start_tag = opening.group()
        present = {prefix for prefix, _ in re.findall(rb'xmlns(?::([\w.-]+))?="([^"]+)"', start_tag)}
        missing = b"".join(b" xmlns" + (b":" + prefix if prefix else b"") + b'="' + uri + b'"'
                           for prefix, uri in original_namespaces if prefix not in present)
        xml = xml[:opening.end() - 1] + missing + xml[opening.end() - 1:]
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=output.parent, suffix=".docx", delete=False) as tmp:
            temp_path = Path(tmp.name)
        try:
            with ZipFile(temp_path, "w", ZIP_DEFLATED) as zout:
                for item in zin.infolist():
                    zout.writestr(item, xml if item.filename == "word/document.xml" else zin.read(item.filename))
            os.link(temp_path, output)
            temp_path.unlink()
        except Exception:
            temp_path.unlink(missing_ok=True)
            raise

def main(argv=None):
    parser = argparse.ArgumentParser(description="Заполнить протокол встречи")
    parser.add_argument("--template", type=Path, default=Path(__file__).resolve().parent.parent / "template.docx")
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.output.resolve() == args.template.resolve() or args.output.resolve() == args.data.resolve():
        raise SystemExit("output не должен совпадать с входным файлом")
    try:
        fill(args.template, json.loads(args.data.read_text(encoding="utf-8")), args.output)
    except (OSError, ValueError, KeyError, json.JSONDecodeError, FileExistsError) as exc:
        parser.error(str(exc))

if __name__ == "__main__": main()
