import importlib.util
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[3] / "scripts" / "sheetmusic" / "prepare_sheetmusic_import.py"
spec = importlib.util.spec_from_file_location("prepare_sheetmusic_import", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)  # type: ignore[union-attr]

PDF_NAME = "score-a4.pdf"
PIECE = {
    "id": "BachJS/BWV999/score",
    "title": "Prelude in D Minor",
    "composer": "BachJS",
    "instrument": "Lute, Guitar",
    "license": "Public Domain",
    "source_url": "https://www.mutopiaproject.org/ftp/BachJS/BWV999/score.ly",
    "pdf_url": "https://www.mutopiaproject.org/ftp/BachJS/BWV999/score-a4.pdf",
}


class PrepareSheetMusicImportTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.catalog = self.root / "catalog.json"
        self.catalog.write_text(json.dumps([PIECE]), encoding="utf-8")
        self.pdf = self.root / PDF_NAME
        self.pdf.write_bytes(b"%PDF-1.4\nlocal test candidate")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_stages_pdf_with_composer_rights_and_source(self) -> None:
        target = module.stage(self.catalog, PIECE["id"], self.pdf, self.root / "staged")

        self.assertEqual((target / PDF_NAME).read_bytes(), self.pdf.read_bytes())
        metadata = ET.parse(target / "metadata.opf").getroot()
        namespaces = {"dc": module.DC}
        self.assertEqual(metadata.find(".//dc:creator", namespaces).text, "BachJS")
        self.assertEqual(metadata.find(".//dc:rights", namespaces).text, "Public Domain")
        self.assertEqual(metadata.find(".//dc:source", namespaces).text, PIECE["source_url"])
        with self.assertRaises(FileExistsError):
            module.stage(self.catalog, PIECE["id"], self.pdf, self.root / "staged")

    def test_rejects_non_pdf_and_wrong_piece(self) -> None:
        self.pdf.write_bytes(b"not a PDF")
        with self.assertRaisesRegex(ValueError, "bounded PDF"):
            module.stage(self.catalog, PIECE["id"], self.pdf, self.root / "staged")
        with self.assertRaisesRegex(ValueError, "exactly once"):
            module.stage(self.catalog, "missing", self.pdf, self.root / "staged")

    def test_rejects_external_pdf_url(self) -> None:
        self.catalog.write_text(json.dumps([{**PIECE, "pdf_url": "https://other.invalid/x.pdf"}]))
        with self.assertRaisesRegex(ValueError, "Mutopia"):
            module.stage(self.catalog, PIECE["id"], self.pdf, self.root / "staged")


if __name__ == "__main__":
    unittest.main()
