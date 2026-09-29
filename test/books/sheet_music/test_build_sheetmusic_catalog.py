import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[3] / "scripts" / "sheetmusic" / "build_sheetmusic_catalog.py"
spec = importlib.util.spec_from_file_location("build_sheetmusic_catalog", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)  # type: ignore[union-attr]


LY = """\\header {
\ttitle =\t\t"Prelude"
\tcomposer =\t"J.S. Bach (1685-1750)"
\t% instrument =\t"Guitar"

\tmutopiatitle =\t"Prelude in D Minor"
\tmutopiacomposer =\t"BachJS"
\tmutopiaopus =\t"BWV 999"
\tmutopiainstrument =\t"Lute, Guitar"
\tstyle =\t\t"Baroque"
\tcopyright =\t"Public Domain"
\tmutopiacopyright = "Public Domain"
\tfooter = "Mutopia-2013/01/22-60"
}

\\version "2.16.1"
"""


def make_piece(root: Path, composer: str, piece: str, text: str = LY, work: str = "work") -> None:
    directory = root / composer / work / piece
    directory.mkdir(parents=True)
    (directory / f"{piece}.ly").write_text(text, encoding="utf-8")


class BuildSheetmusicCatalogTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_parses_header_fields_into_catalog_entry(self) -> None:
        make_piece(self.root, "BachJS", "Bach_Prelude_BWV999", work="BWV999")

        catalog = module.build_catalog(self.root)

        entry = catalog[0]
        self.assertEqual(entry["id"], "BachJS/BWV999/Bach_Prelude_BWV999/Bach_Prelude_BWV999")
        self.assertEqual(entry["title"], "Prelude in D Minor")
        self.assertEqual(entry["composer"], "BachJS")
        self.assertEqual(entry["opus"], "BWV 999")
        self.assertEqual(entry["instrument"], "Lute, Guitar")
        self.assertEqual(entry["style"], "Baroque")
        self.assertEqual(entry["license"], "Public Domain")
        self.assertIn("mutopiaproject.org", entry["source_url"])
        self.assertTrue(entry["pdf_url"].endswith("Bach_Prelude_BWV999-a4.pdf"))

    def test_skips_pieces_with_missing_required_header(self) -> None:
        make_piece(self.root, "BachJS", "ok")
        incomplete = LY.replace('copyright =\t"Public Domain"', "").replace(
            'mutopiacopyright = "Public Domain"', ""
        ).replace(
            'footer = "Mutopia-2013/01/22-60"', ""
        )
        make_piece(self.root, "BachJS", "no_license", incomplete)
        (self.root / "Nobody").mkdir()

        catalog = module.build_catalog(self.root)

        self.assertEqual([entry["id"] for entry in catalog], ["BachJS/work/ok/ok"])

    def test_max_entries_limit_stops_collection(self) -> None:
        make_piece(self.root, "A", "one")
        make_piece(self.root, "B", "two")

        with mock.patch.object(module, "MAX_ENTRIES", 1):
            catalog = module.build_catalog(self.root)

        self.assertEqual(len(catalog), 1)

    def test_overlong_field_value_skips_entry(self) -> None:
        text = LY.replace('"Prelude in D Minor"', '"' + "T" * 301 + '"')
        make_piece(self.root, "BachJS", "long", text)

        catalog = module.build_catalog(self.root)

        self.assertEqual(catalog, [])

    def test_rejects_lilypond_markup_instead_of_published_license(self) -> None:
        text = LY.replace('mutopiacopyright = "Public Domain"', '')
        text = text.replace('copyright =\t"Public Domain"',
                            'copyright = \\markup { arbitrary }')
        make_piece(self.root, "BachJS", "markup", text)
        self.assertEqual(module.build_catalog(self.root), [])

    def test_main_writes_json(self) -> None:
        make_piece(self.root / "ftp", "BachJS", "Bach_Prelude_BWV999")
        out = self.root / "catalog.json"
        argv = ["build_sheetmusic_catalog.py", str(self.root / "ftp"), str(out)]

        with mock.patch("sys.argv", argv):
            rc = module.main()

        self.assertEqual(rc, 0)
        catalog = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(len(catalog), 1)
