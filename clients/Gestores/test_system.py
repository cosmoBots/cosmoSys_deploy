import json,tempfile,unittest,uuid,urllib.request,urllib.error,threading,http.cookiejar
from pathlib import Path
from store import Store
import cosmosys_client as c
import application
from unittest.mock import patch
from server import handler,ThreadingHTTPServer

class PersistenceTests(unittest.TestCase):
 def test_revision_and_idempotency(self):
  with tempfile.TemporaryDirectory() as td:
   s=Store(Path(td)/'data.db');s.add('a','p','issue:1','Obra')
   self.assertEqual(s.add('b','p','issue:1','Obra')['id'],'a')
   self.assertEqual(s.save_notes('a','issue:2',{'objective':'Uno'},0),1)
   self.assertEqual(s.save_notes('a','issue:2',{'objective':'Uno'},0),1)
   with self.assertRaises(ValueError):s.save_notes('a','issue:2',{'objective':'Dos'},0)
 def test_http_session_csrf_host(self):
  with tempfile.TemporaryDirectory() as td:
   old=application.ROOT;application.ROOT=Path(td)
   try:a=application.Application('historias')
   finally:application.ROOT=old
   server=ThreadingHTTPServer(('127.0.0.1',0),handler(a));a.port=server.server_port
   thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
   base=f'http://127.0.0.1:{a.port}'
   try:
    with self.assertRaises(urllib.error.HTTPError) as e:urllib.request.urlopen(base+'/api/session')
    self.assertEqual(e.exception.code,401)
    jar=http.cookiejar.CookieJar();opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    # Redirect destination is absent from temporary fixture, but the cookie is installed.
    try:opener.open(base+'/abrir?clave='+a.key)
    except Exception:pass
    token=json.load(opener.open(base+'/api/session'))['csrf']
    with self.assertRaises(urllib.error.HTTPError) as e:opener.open(urllib.request.Request(base+'/api/init',data=b'{}',headers={'Content-Type':'application/json'}))
    self.assertEqual(e.exception.code,403)
    with self.assertRaises(urllib.error.HTTPError) as e:opener.open(urllib.request.Request(base+'/api/session',headers={'Host':'evil.example'}))
    self.assertEqual(e.exception.code,401)
    self.assertTrue(token)
    with patch('cosmosys_client.authenticate',return_value='fran'):
     req=urllib.request.Request(base+'/login',data=b'{"login":"fran","password":"test"}',headers={'Origin':base,'X-Login-Request':'1','Content-Type':'application/json'})
     self.assertTrue(json.load(opener.open(req))['ok'])
    with patch('cosmosys_client.authenticate',side_effect=ValueError('Incorrecto')):
     with self.assertRaises(urllib.error.HTTPError) as e:opener.open(req)
     self.assertEqual(e.exception.code,401)
   finally:server.shutdown();server.server_close()

if __name__=='__main__':unittest.main()
