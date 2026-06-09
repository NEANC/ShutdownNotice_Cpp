#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Normalize install-core.ps1 / install.ps1 to UTF-8 with BOM + CRLF line endings."""

from pathlib import Path

BOM = b"\xEF\xBB\xBF"
FILES = ["install-core.ps1", "install.ps1"]
ROOT = Path(__file__).resolve().parent


def normalize_file(path: Path) -> None:
    data = path.read_bytes()

    # 1. Strip all leading BOMs to avoid duplicate BOMs.
    bom_count = 0
    while data.startswith(BOM):
        bom_count += 1
        data = data[len(BOM):]

    # 2. Normalize all line endings to CRLF.
    data = (
        data
        .replace(b"\r\n", b"\n")
        .replace(b"\r", b"\n")
        .replace(b"\n", b"\r\n")
    )

    # 3. Write back as UTF-8 with BOM + CRLF.
    path.write_bytes(BOM + data)

    print(f"OK: {path.name} - stripped {bom_count} BOM(s), normalized to UTF-8 with BOM + CRLF")


def main() -> None:
    for name in FILES:
        path = ROOT / name

        if not path.exists():
            print(f"SKIP: {name} does not exist")
            continue

        normalize_file(path)

    print("Done.")


if __name__ == "__main__":
    main()
