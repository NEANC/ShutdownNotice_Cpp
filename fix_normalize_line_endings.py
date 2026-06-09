#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""规范化 .ps1 文件的编码与换行符：

    install-core.ps1 → UTF-8 with BOM + CRLF（写入文件后执行）
    install.ps1      → UTF-8 without BOM + CRLF（通过 irm | iex 管道执行）
"""

from pathlib import Path

BOM = b"\xEF\xBB\xBF"
ROOT = Path(__file__).resolve().parent

# (文件名, 是否需要 BOM)
FILES = [
    ("install-core.ps1", True),
    ("install.ps1", False),
]


def normalize_file(path: Path, *, with_bom: bool) -> None:
    """校验 UTF-8 编码后统一 CRLF 换行，按需设置 BOM。"""
    data = path.read_bytes()

    # 1. 剥离所有已有 BOM
    bom_count = 0
    while data.startswith(BOM):
        bom_count += 1
        data = data[len(BOM):]

    # 2. 严格按 UTF-8 解码，拒绝 GBK/ANSI 等非 UTF-8 编码
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SystemExit(
            f"ERROR: {path.name} 不是有效的 UTF-8 编码，请先转换为 UTF-8。\n"
            f"详情: {exc}"
        ) from exc

    # 3. 统一换行为 CRLF
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = text.replace("\n", "\r\n")

    # 4. 按规则写回
    output = text.encode("utf-8")
    if with_bom:
        output = BOM + output
    path.write_bytes(output)

    bom_label = "with BOM" if with_bom else "without BOM"
    print(
        f"OK: {path.name} - stripped {bom_count} BOM(s), "
        f"UTF-8 {bom_label} + CRLF"
    )


def main() -> None:
    for name, with_bom in FILES:
        path = ROOT / name
        if not path.exists():
            print(f"SKIP: {name} does not exist")
            continue
        normalize_file(path, with_bom=with_bom)
    print("Done.")


if __name__ == "__main__":
    main()
