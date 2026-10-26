import base64
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
from xml.etree import ElementTree as E
import application
import apa7
import bridge

class Tests(unittest.TestCase):
    def fixture(self):
        records=[dict(key='section:'+str(i),parent=None if i==0 else 'section:'+str(i-1),revision=1,
                      label='Apartado',editable=['subject','description'],fields={'subject':str(i)+'. Título '+str(i),'description':'Primer párrafo.\nSegundo párrafo.'}) for i in range(6)]
        return bridge.branch(dict(format=1,service='cosmoSys',storage='academic-local',document_id='doc',project={'identifier':'test','name':'Test'},records=records),'section:0')
    def edit(self,path,old,new):
        with zipfile.ZipFile(path) as z:parts={n:z.read(n) for n in z.namelist()}
        doc=E.fromstring(parts['word/document.xml']);changed=False
        for n in doc.iter(apa7.tag('t')):
            if n.text==old:n.text=new;changed=True;break
        self.assertTrue(changed);parts['word/document.xml']=bridge.xml(doc)
        with zipfile.ZipFile(path,'w') as z:
            for n,v in parts.items():z.writestr(n,v)
    def test_five_levels_determinism_changes_and_frozen_cover(self):
        m=self.fixture();settings={'author':'Autor','affiliation':'Universidad','course':'TFG','instructor':'Tutora','due_date':'2027'}
        with tempfile.TemporaryDirectory() as td:
            a,b=[Path(td)/n for n in ('a.docx','b.docx')]
            for p in (a,b):apa7.write(m,{},settings,p)
            self.assertEqual(a.read_bytes(),b.read_bytes())
            original,values=apa7.read(a);self.assertEqual([],bridge.plan(original,values))
            with zipfile.ZipFile(a) as z:
                doc=E.fromstring(z.read('word/document.xml'))
                self.assertEqual(2,len([p for p in doc.findall('.//'+apa7.tag('p')) if len(p.findall(apa7.tag('sdt')))==3]))
                self.assertIn(b'PAGE',z.read('word/header1.xml'))
            self.edit(a,'Primer párrafo.','Corrección verificable.')
            original,values=apa7.read(a);changes=bridge.plan(original,values)
            self.assertEqual(1,len(changes));self.assertIn('Corrección verificable.',changes[0]['after']['description'])
            self.edit(b,'Autor','Otro autor')
            with self.assertRaisesRegex(ValueError,'Portada'):apa7.read(b)
    def test_exclusion_and_references(self):
        m=self.fixture();notes={'section:3':{'data':{'export_role':'exclude'}}}
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'a.docx';result=apa7.write(m,notes,{},p)
            self.assertEqual(3,result['excluded']);self.assertIn('Autor pendiente',result['warnings'])
            loaded,values=apa7.read(p);self.assertEqual(3,len(loaded['records']));self.assertEqual([],bridge.plan(loaded,values))
    def test_instance_metadata_and_apa_corrections_never_write_universe(self):
        with tempfile.TemporaryDirectory() as td,patch.object(application,'ROOT',Path(td)):
            app=application.Application('academico')
            with patch.object(application.client,'snapshot',return_value={'records':[{'key':'issue:1'}]}),patch.object(application.client,'server') as remote:
                p={'project':'universe','source':'issue:1','title':'TFG','token':'test'}
                work=app.api('/api/create-instance',p)
                self.assertEqual(work,app.api('/api/create-instance',p))
                another=app.api('/api/create-instance',dict(p,token='second',title='Otro TFG'))
                self.assertNotEqual(work['root'],another['root'])
                app.api('/api/save-publication',{'work':work['id'],'data':{'author':'Autor'},'revision':0})
                with self.assertRaises(ValueError):app.api('/api/save-publication',{'work':work['id'],'data':{'author':'Cambio'},'revision':0})
                _,_,m=app.snapshot(work['id']);f=Path(td)/'a.docx'
                apa7.write(m,app.store.notes(work['id']),{'author':'Autor'},f)
                self.edit(f,'Método','Procedimiento')
                preview=app.api('/api/import-preview',{'work':work['id'],'file':base64.b64encode(f.read_bytes()).decode()})
                self.assertEqual(1,len(preview['changes']))
                app.api('/api/import-apply',{'work':work['id'],'token':preview['token']})
                _,_,fresh=app.snapshot(work['id']);self.assertTrue(any(r['fields']['subject']=='Procedimiento' for r in fresh['records']))
                remote.assert_not_called()
