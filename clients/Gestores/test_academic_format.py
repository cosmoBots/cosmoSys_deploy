import tempfile
import unittest
import zipfile
from pathlib import Path
from xml.etree import ElementTree as E
import application
from academic_format import apply_base_format,tag


class Tests(unittest.TestCase):
    def test_deterministic_format_preserves_reversible_fields(self):
        b=application.bridge
        manifest={'format':1,'service':'cosmoSys','project':{'id':1,'identifier':'test','name':'Prueba'},
            'records':[{'key':'issue:1','label':'Apartado','revision':1,'editable':['subject','description'],
                'fields':{'subject':'Percepción','description':'Texto con ñ.\n\nSegundo párrafo.'}}]}
        with tempfile.TemporaryDirectory() as folder:
            paths=[Path(folder)/name for name in ('a.docx','b.docx')]
            for path in paths:
                b.write_docx(manifest,path);apply_base_format(path)
                m,v=b.read_docx(path)
                self.assertEqual([],b.plan(m,v))
            self.assertEqual(paths[0].read_bytes(),paths[1].read_bytes())
            with zipfile.ZipFile(paths[0]) as archive:
                document=E.fromstring(archive.read('word/document.xml'))
                self.assertEqual('1440',next(document.iter(tag('pgMar'))).get(tag('left')))
                styles=E.fromstring(archive.read('word/styles.xml'))
                self.assertTrue(all(s.get(tag('line'))=='480' for s in styles.iter(tag('spacing'))))
