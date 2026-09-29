#!/usr/bin/env python3
"""Stage one locally obtained Mutopia PDF and its licensed OPF; never downloads.

Usage: prepare_sheetmusic_import.py CATALOG.json PIECE_ID PDF-file OUTPUT-dir
Review the staged PDF and OPF before an administrator imports them into Jellyfin.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote, urlparse

MAX_PDF_BYTES = 100 * 1024 * 1024
DC = "http://purl.org/dc/elements/1.1/"
OPF = "http://www.idpf.org/2007/opf"
ET.register_namespace("dc", DC)
ET.register_namespace("", OPF)


def _mutopia_url(value: str, suffix: str) -> bool:
    try:
        url = urlparse(value)
        return (
            url.scheme == "https"
            and url.hostname == "www.mutopiaproject.org"
            and url.port in (None, 443)
            and not url.username
            and not url.query
            and not url.fragment
            and url.path.startswith("/ftp/")
            and url.path.lower().endswith(suffix)
        )
    except ValueError:
        return False


def stage(catalog_path: Path, piece_id: str, pdf_path: Path, output_root: Path) -> Path:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    if not isinstance(catalog, list):
        raise ValueError("catalog must be a JSON array")
    matches = [item for item in catalog if isinstance(item, dict) and item.get("id") == piece_id]
    if len(matches) != 1:
        raise ValueError("piece ID must occur exactly once in the catalog")
    piece = matches[0]
    for field in ("title", "composer", "license", "source_url", "pdf_url"):
        if not isinstance(piece.get(field), str) or not piece[field].strip():
            raise ValueError(f"missing {field}")
    if not _mutopia_url(piece["source_url"], ".ly") or not _mutopia_url(piece["pdf_url"], ".pdf"):
        raise ValueError("catalog URLs must point to Mutopia source and PDF files")
    expected_name = Path(unquote(urlparse(piece["pdf_url"]).path)).name
    if pdf_path.name != expected_name or not pdf_path.is_file():
        raise ValueError(f"expected local PDF named {expected_name}")
    with pdf_path.open("rb") as stream:
        has_pdf_header = stream.read(5) == b"%PDF-"
    if pdf_path.stat().st_size > MAX_PDF_BYTES or not has_pdf_header:
        raise ValueError("local file is not a bounded PDF candidate")

    slug = re.sub(r"[^a-z0-9]+", "-", f"{piece['composer']}-{piece['title']}".lower()).strip("-")[:80]
    folder = f"{slug or 'sheet-music'}-{hashlib.sha256(piece_id.encode()).hexdigest()[:8]}"
    output_root.mkdir(parents=True, exist_ok=True)
    target = output_root / folder
    target.mkdir(exist_ok=False)
    staged_pdf = target / expected_name
    shutil.copyfile(pdf_path, staged_pdf)

    package = ET.Element(f"{{{OPF}}}package", {"version": "2.0", "unique-identifier": "bookid"})
    metadata = ET.SubElement(package, f"{{{OPF}}}metadata")
    ET.SubElement(metadata, f"{{{DC}}}identifier", {"id": "bookid"}).text = piece_id
    for field, value in (
        ("title", piece["title"]),
        ("creator", piece["composer"]),
        ("rights", piece["license"]),
        ("source", piece["source_url"]),
        ("description", "Instrument: " + (piece.get("instrument") or "unknown")),
    ):
        ET.SubElement(metadata, f"{{{DC}}}{field}").text = value
    ET.ElementTree(package).write(target / "metadata.opf", encoding="utf-8", xml_declaration=True)
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path)
    parser.add_argument("piece_id")
    parser.add_argument("pdf", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    target = stage(args.catalog, args.piece_id, args.pdf, args.output)
    pdf = next(target.glob("*.pdf"))
    print(f"staged: {target}")
    with pdf.open("rb") as stream:
        print(f"sha256: {hashlib.file_digest(stream, 'sha256').hexdigest()}")


if __name__ == "__main__":
    main()
