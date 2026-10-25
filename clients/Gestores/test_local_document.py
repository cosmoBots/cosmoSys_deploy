import tempfile,unittest
from pathlib import Path
from unittest.mock import patch
import application
from store import Store


class Tests(unittest.TestCase):
    def test_local_instance_roundtrip_and_conflict_without_universe_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(application,'ROOT',Path(folder)):
                app=application.Application('academico')
            records=[{'key':'section:root','parent':None,'fields':{'subject':'TFG','description':'Introducción'}},
                     {'key':'section:method','parent':'section:root','fields':{'subject':'Método','description':'Propuesta'}}]
            app.store.add_document('doc','universe','TFG',records)
            with patch.object(application.client,'snapshot',return_value={'records':[]}),patch.object(application.client,'server') as remote:
                w,s,b=app.snapshot('doc')
                path=Path(folder)/'tfg.docx';application.bridge.write_docx(b,path)
                m,v=application.bridge.read_docx(path)
                self.assertEqual('doc',m['document_id']);self.assertEqual([],application.bridge.plan(m,v))
                change={'key':'section:method','revision':1,'before':{'description':'Propuesta'},'after':{'description':'Revisada'}}
                app.changes(w,[change],True)
                self.assertEqual('Propuesta',app.snapshot('doc')[2]['records'][1]['fields']['description'])
                app.changes(w,[change]);app.changes(w,[change])
                with self.assertRaises(ValueError):app.changes(w,[dict(change,after={'description':'Obsoleta'})])
                self.assertEqual('Revisada',app.snapshot('doc')[2]['records'][1]['fields']['description'])
                remote.assert_not_called()
            with self.assertRaises(ValueError):app.store.add_document('doc','universe','TFG',records)
