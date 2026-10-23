import json
import threading
import unittest
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
