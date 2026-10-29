#!/usr/bin/env python3
"""Check repository-owned Markdown links without accessing external websites."""
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def main():
    errors = []
    files = list(ROOT.glob("*.md"))
    for directory in ("docs", "examples"):
        files.extend((ROOT / directory).rglob("*.md"))
    for path in sorted(files):
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            for target in re.findall(r"\]\(([^)]+)\)", line):
                target = target.strip().strip("<>")
                url = urlsplit(target)
                if url.scheme or url.netloc or not url.path:
                    continue
                if not (path.parent / unquote(url.path)).exists():
                    errors.append(f"{path.relative_to(ROOT)}:{line_number}: missing {target}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Checked local links in {len(files)} Markdown files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
