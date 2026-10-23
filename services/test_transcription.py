import json
import threading
import unittest
import tempfile
from audio_archive import AudioArchive
from pathlib import Path
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from transcription_server import handler


class Provider:
    def __init__(self):self.paths=[]
    def transcribe(self,path):
        self.paths.append(path)
        assert Path(path).read_bytes()==b'synthetic'
        return [{'start':0,'end':1,'text':'prueba'}]


class Tests(unittest.TestCase):
    def test_archived_failure_retry_other_engine_and_auth(self):
        class Failed:
            def transcribe(self,path):raise RuntimeError('private diagnostic')
        with tempfile.TemporaryDirectory() as folder:
            archive=AudioArchive(folder)
            server=ThreadingHTTPServer(('127.0.0.1',0),handler(Failed(),'t'*32,archive,
                {'faster-whisper':Failed(),'alternative':Provider()}))
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            def request(path,body=None,token='t'*32,ctype='application/json'):
                connection=HTTPConnection('127.0.0.1',server.server_port,timeout=3)
                connection.request('GET' if body is None else 'POST',path,body,
                    {'Authorization':'Bearer '+token,'Content-Type':ctype})
                response=connection.getresponse();result=response.status,json.loads(response.read())
                connection.close();return result
            try:
                self.assertEqual(401,request('/v1/transcription-engines',token='bad')[0])
                self.assertIn('alternative',request('/v1/transcription-engines')[1]['engines'])
                status,result=request('/v1/transcriptions',b'synthetic',ctype='application/octet-stream')
                self.assertEqual(502,status)
                identity=result['audio_id']
                self.assertNotIn('private diagnostic',str(result))
                payload=json.dumps({'audio_id':identity,'engine':'alternative'})
                self.assertEqual(401,request('/v1/transcriptions/retry',payload,token='bad')[0])
                status,result=request('/v1/transcriptions/retry',payload)
                self.assertEqual(200,status);self.assertEqual(identity,result['audio_id'])
                self.assertEqual('alternative',result['engine'])
                self.assertEqual(422,request('/v1/transcriptions/retry',json.dumps({'audio_id':'../x','engine':'alternative'}))[0])
                self.assertEqual(422,request('/v1/transcriptions/retry',json.dumps({'audio_id':identity,'engine':'unknown'}))[0])
                self.assertEqual(404,request('/v1/transcriptions/retry',json.dumps({'audio_id':'0'*64,'engine':'alternative'}))[0])
                with archive.connect() as db:
                    self.assertEqual([('failed',),('complete',)],db.execute('SELECT status FROM attempts ORDER BY rowid').fetchall())
            finally:
                server.shutdown();server.server_close();thread.join()

    def test_http_audio_and_cleanup(self):
        provider=Provider()
        server=ThreadingHTTPServer(('127.0.0.1',0),handler(provider,'t'*32))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        def request(token,ctype='application/octet-stream'):
            connection=HTTPConnection('127.0.0.1',server.server_port,timeout=3)
            connection.request('POST','/v1/transcriptions',b'synthetic',
                {'Authorization':'Bearer '+token,'Content-Type':ctype})
            response=connection.getresponse();result=response.status,json.loads(response.read())
            connection.close();return result
        try:
            self.assertEqual(401,request('wrong')[0])
            self.assertEqual(415,request('t'*32,'application/json')[0])
            self.assertEqual([],provider.paths)
            status,result=request('t'*32)
            self.assertEqual(200,status);self.assertTrue(result['review_required'])
        finally:
            server.shutdown();server.server_close();thread.join()
        self.assertFalse(Path(provider.paths[0]).exists())
