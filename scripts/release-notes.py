#!/usr/bin/env python3
"""Prints the GitHub release notes for one version.

Uses release-notes/<version>.md as is when it exists. Otherwise takes the
"## <version> — <date>" section of CHANGELOG.md and reshapes it the way the
published notes look: headings one level up, hard-wrapped lines joined back
into one line per paragraph or list item.

An optional third argument is appended as the closing line.

Exits with status 1 when neither source has the version.
"""

import pathlib
import re
import sys


def is_wide(ch: str) -> bool:
    return ord(ch) > 0x2E7F


def join_lines(prev: str, cur: str) -> str:
    # Japanese wraps without a space; anything next to Latin text keeps one,
    # matching how the changelog spaces English words inside Japanese.
    if prev and cur and is_wide(prev[-1]) and is_wide(cur[0]):
        return prev + cur
    if prev and cur and (prev[-1] in "。、）」』！？：" or cur[0] in "（「『"):
        return prev + cur
    return prev + " " + cur


def section_from_changelog(text: str, version: str) -> list[str] | None:
    lines = text.splitlines()
    head = re.compile(rf"^## {re.escape(version)}(\s|$)")
    start = next((i for i, l in enumerate(lines) if head.match(l)), None)
    if start is None:
        return None
    body = []
    for line in lines[start + 1:]:
        if line.strip() == "---" or line.startswith("## "):
            break
        body.append(line)
    return body


def reshape(body: list[str]) -> str:
    blocks: list[str] = []
    current: str | None = None
    in_code = False
    for raw in body:
        line = raw.rstrip()
        if line.lstrip().startswith("```"):
            if current is not None:
                blocks.append(current)
                current = None
            in_code = not in_code
            blocks.append(line)
            continue
        if in_code:
            blocks.append(line)
            continue
        stripped = line.strip()
        if not stripped:
            if current is not None:
                blocks.append(current)
                current = None
            blocks.append("")
            continue
        if stripped.startswith("#"):
            if current is not None:
                blocks.append(current)
                current = None
            blocks.append(stripped[1:] if stripped.startswith("###") else stripped)
            continue
        starts_item = re.match(r"^(\s*)([-*]|\d+\.)\s", line) is not None
        starts_table = stripped.startswith("|")
        if current is None or starts_item or starts_table or current.lstrip().startswith("|"):
            if current is not None:
                blocks.append(current)
            current = line
        else:
            current = join_lines(current, stripped)
    if current is not None:
        blocks.append(current)

    text = "\n".join(blocks)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return text


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print("使い方: release-notes.py <プロジェクトのフォルダ> <バージョン> [末尾に足す一文]", file=sys.stderr)
        return 2
    project = pathlib.Path(sys.argv[1])
    version = sys.argv[2]
    footer = sys.argv[3] if len(sys.argv) == 4 else ""

    hand_written = project / "release-notes" / f"{version}.md"
    if hand_written.exists():
        print(hand_written.read_text(encoding="utf-8").strip())
        return 0

    changelog = project / "CHANGELOG.md"
    if not changelog.exists():
        print(f"エラー: release-notes/{version}.md も CHANGELOG.md もありません。", file=sys.stderr)
        return 1
    body = section_from_changelog(changelog.read_text(encoding="utf-8"), version)
    if body is None:
        print(f"エラー: CHANGELOG.md に「## {version}」の項目がありません。", file=sys.stderr)
        return 1
    notes = reshape(body)
    if not notes:
        print(f"エラー: CHANGELOG.md の {version} の項目が空です。", file=sys.stderr)
        return 1
    print(notes + ("\n\n" + footer if footer else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
