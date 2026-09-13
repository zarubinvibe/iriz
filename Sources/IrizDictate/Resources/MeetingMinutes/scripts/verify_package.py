#!/usr/bin/env python3
"""Проверка контрольных сумм переносимого комплекта. Только стандартная библиотека."""

import hashlib
import json
from pathlib import Path
import sys
import zipfile


def main():
    root = Path(__file__).resolve().parent.parent
    try:
        manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        entries = manifest["files"]
        if not isinstance(entries, dict) or not entries:
            raise ValueError("пустой или некорректный перечень файлов")
        errors = []
        for name, expected in entries.items():
            file = (root / name).resolve()
            if not file.is_relative_to(root) or not file.is_file():
                errors.append(f"нет файла или путь вне комплекта: {name}")
                continue
            actual = hashlib.sha256(file.read_bytes()).hexdigest()
            if actual != expected:
                errors.append(f"файл изменен: {name}")
        with zipfile.ZipFile(root / "template.docx") as package:
            broken = package.testzip()
            if broken:
                errors.append(f"поврежден DOCX: {broken}")
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        print(f"Комплект цел: проверено файлов — {len(entries)}.")
        print("Проверены контрольные суммы, а не содержание заполненного протокола.")
        return 0
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print(f"Проверка не выполнена: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
