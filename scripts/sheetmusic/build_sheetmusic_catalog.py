#!/usr/bin/env python3
"""Build a sheet-music catalog JSON from a local MutopiaProject git checkout.

The MutopiaProject archive publishes every piece as a LilyPond file with a
structured header (mutopiatitle, mutopiacomposer, mutopiaopus,
mutopiainstrument, style, copyright, footer). This script parses those headers
from a locally pinned checkout - it performs no network access and does not
scrape the website. Output entries carry provenance and the per-piece license
exactly as published.

Usage:
  python3 build_sheetmusic_catalog.py <mutopia-checkout>/ftp <output.json>
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.parse import quote

MAX_FILE_BYTES = 512 * 1024
MAX_ENTRIES = 50_000
MAX_FIELD = 300

REQUIRED = ("mutopiatitle", "mutopiacomposer", "footer")
FIELDS = {
    "title": "mutopiatitle",
    "composer": "mutopiacomposer",
    "opus": "mutopiaopus",
    "instrument": "mutopiainstrument",
    "style": "style",
}


def published_license(header: dict[str, str]) -> str | None:
    value = header.get("mutopiacopyright") or header.get("copyright", "")
    if value == "Public Domain" or value.startswith("Creative Commons "):
        return value if len(value) <= MAX_FIELD and "\\" not in value else None
    return None


def parse_header(text: str) -> dict[str, str]:
    header: dict[str, str] = {}
    inside = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("\\header"):
            inside = True
            continue
        if not inside:
            continue
        if line.startswith("}"):
            break
        if line.startswith("%"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        value = value.strip().strip('"').strip()
        if key and value and len(value) <= MAX_FIELD:
            header.setdefault(key, value)
    return header


def build_catalog(ftp_root: Path) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    for ly in sorted(ftp_root.rglob("*.ly")):
        relative = ly.relative_to(ftp_root)
        if len(relative.parts) < 3 or not ly.resolve().is_relative_to(ftp_root.resolve()):
            continue
        try:
            if ly.stat().st_size > MAX_FILE_BYTES:
                continue
            text = ly.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        header = parse_header(text)
        license_name = published_license(header)
        if not all(header.get(key) for key in REQUIRED) or not license_name:
            continue
        piece_id = relative.with_suffix("").as_posix()
        # This PDF naming pattern is verified for two examples; validate a
        # pinned catalog before serving it to users.
        base = "https://www.mutopiaproject.org/ftp/"
        pdf_path = relative.with_name(f"{ly.stem}-a4.pdf").as_posix()
        entry = {
            "id": piece_id,
            "pdf_url": base + quote(pdf_path, safe="/"),
            "source_url": base + quote(relative.as_posix(), safe="/"),
            "license": license_name,
        }
        for out_key, header_key in FIELDS.items():
            value = header.get(header_key)
            if value:
                entry[out_key] = value
        entries.append(entry)
        if len(entries) >= MAX_ENTRIES:
            return entries
    return entries


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    ftp_root = Path(sys.argv[1])
    if not ftp_root.is_dir():
        print(f"not a directory: {ftp_root}", file=sys.stderr)
        return 2
    catalog = build_catalog(ftp_root)
    Path(sys.argv[2]).write_text(
        json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"wrote {len(catalog)} entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
