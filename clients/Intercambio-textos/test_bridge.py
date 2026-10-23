import copy
import tempfile
import unittest
import zipfile
from pathlib import Path
from xml.etree import ElementTree as E
import bridge as b

SAMPLE = {"format": 1, "service": "CGRol", "project": {"id": 13, "identifier": "phuturwrld", "name": "PhuturWRLD"},
          "records": [
              {"key": "issue:99", "label": "Ficha PHUT-99", "revision": 4, "editable": ["subject", "description"],
               "fields": {"subject": "Escena de prueba", "description": "Dos líneas con ñ y á.\n\nSegunda línea con\tun tabulador.\n",
                          "cs_roll_result": "6"}},
              {"key": "wiki:80", "label": "Página Prueba", "revision": 2, "editable": ["text"],
               "fields": {"text": ""}}]}


def edit_docx(source, dest, field, value):
    with zipfile.ZipFile(source) as z:
        parts = {name: z.read(name) for name in z.namelist()}
    doc = E.fromstring(parts["word/document.xml"])
    for sdt in doc.findall(".//w:sdt", b.NS):
        if sdt.find("w:sdtPr/w:tag", b.NS).get(b.wtag("val")) == field:
            content = sdt.find("w:sdtContent", b.NS)
            content.clear()
            for line in value.split("\n"):
                content.append(b.paragraph(line))
    parts["word/document.xml"] = b.xml(doc)
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
        for name, raw in parts.items():
            z.writestr(name, raw)


class ExchangeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
    def tearDown(self):
        self.tmp.cleanup()

    def test_deterministic_docx_and_txt(self):
        for suffix, writer in [(".docx", b.write_docx), (".txt", b.write_txt)]:
            one, two = self.root / ("a" + suffix), self.root / ("b" + suffix)
            writer(SAMPLE, one); writer(SAMPLE, two)
            self.assertEqual(one.read_bytes(), two.read_bytes())
            manifest, values = b.read_document(one)
            self.assertEqual(b.plan(manifest, values), [])
            for r in SAMPLE["records"]:
                for f, value in r["fields"].items():
                    self.assertEqual(values[r["key"] + ":" + f], value)

    def test_edit_import_export_preserves_text(self):
        original, edited = self.root / "original.docx", self.root / "edited.docx"
        b.write_docx(SAMPLE, original)
        correction = "Ahora hay un cambio.\n\nY otra línea.  "
        edit_docx(original, edited, "issue:99:description", correction)
        manifest, values = b.read_docx(edited)
        changes = b.plan(manifest, values)
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0]["after"], {"description": correction})
        updated = copy.deepcopy(SAMPLE)
        updated["records"][0]["fields"]["description"] = changes[0]["after"]["description"]
        updated["records"][0]["revision"] += 1
        b.write_docx(updated, original)
        _, reexported = b.read_docx(original)
        self.assertEqual(values, reexported)

    def test_readonly_and_missing_identity(self):
        one, two = self.root / "a.docx", self.root / "b.docx"
        b.write_docx(SAMPLE, one)
        edit_docx(one, two, "issue:99:cs_roll_result", "20")
        manifest, values = b.read_docx(two)
        with self.assertRaises(ValueError):
            b.plan(manifest, values)
        with zipfile.ZipFile(one) as source, zipfile.ZipFile(two, "w") as dest:
            for n in source.namelist():
                if n != "docProps/custom.xml":
                    dest.writestr(n, source.read(n))
        with self.assertRaises(KeyError):
            b.read_docx(two)

    def test_signed_baseline_tamper_rejected(self):
        envelope = b.sign(copy.deepcopy(SAMPLE))
        envelope["manifest"]["project"]["identifier"] = "otro-proyecto"
        with self.assertRaises(ValueError):
            b.verify(envelope)

    def test_txt_edit_and_deleted_block(self):
        path = self.root / "a.txt"
        b.write_txt(SAMPLE, path)
        text = path.read_text(encoding="utf-8").replace("Escena de prueba", "Escena corregida")
        path.write_text(text, encoding="utf-8")
        manifest, values = b.read_txt(path)
        self.assertEqual(b.plan(manifest, values)[0]["after"]["subject"], "Escena corregida")
        path.write_text(text.replace("[[CS-END wiki:80:text]]", ""), encoding="utf-8")
        with self.assertRaises(ValueError):
            b.read_txt(path)

    def test_tracked_changes_rejected(self):
        one, two = self.root / "a.docx", self.root / "b.docx"
        b.write_docx(SAMPLE, one)
        with zipfile.ZipFile(one) as source, zipfile.ZipFile(two, "w") as dest:
            for name in source.namelist():
                raw = source.read(name)
                if name == "word/document.xml":
                    root = E.fromstring(raw)
                    E.SubElement(root.find("w:body", b.NS), b.wtag("ins"))
                    raw = b.xml(root)
                dest.writestr(name, raw)
        with self.assertRaises(ValueError):
            b.read_docx(two)


if __name__ == "__main__":
    unittest.main()
