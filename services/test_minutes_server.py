import hashlib
import json
import threading
import unittest
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from inference import RemoteInference
from inference_server import handler as inference_handler
from minutes_server import handler
from minutes import Minutes


class Provider:
    def __init__(self): self.calls=0
    def chat(self,payload):
        self.calls+=1
        text=payload['messages'][-1]['content'].split('\n',1)[1]
        citation='invented' if text=='bad evidence' else text
        return {'message':{'content':json.dumps({'temas':[{'texto':'Tema','cita':citation}],
                'decisiones':[],'acciones':[],'pendientes':[]})}}


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.provider=Provider()
        self.upstream=ThreadingHTTPServer(('127.0.0.1',0),inference_handler(self.provider,'i'*32))
        engine=Minutes(RemoteInference('http://127.0.0.1:'+str(self.upstream.server_port),'i'*32))
        self.api=ThreadingHTTPServer(('127.0.0.1',0),handler(engine,'m'*32))
        self.threads=[]
        for server in (self.upstream,self.api):
            thread=threading.Thread(target=server.serve_forever,daemon=True)
            thread.start();self.threads.append(thread)

    def tearDown(self):
        for server in (self.api,self.upstream): server.shutdown();server.server_close()
        for thread in self.threads: thread.join()

    def request(self,data,token='m'*32,path='/v1/minutes/draft'):
        connection=HTTPConnection('127.0.0.1',self.api.server_port,timeout=5)
        connection.request('POST',path,json.dumps(data),{'Content-Type':'application/json','Authorization':'Bearer '+token})
        response=connection.getresponse();result=response.status,json.loads(response.read())
        connection.close();return result

    def test_two_http_services_produce_reviewable_draft(self):
        text='Revisamos el proyecto.'
        status,result=self.request({'transcript':text})
        self.assertEqual(200,status)
        self.assertTrue(result['review_required'])
        self.assertEqual('draft',result['status'])
        self.assertEqual(hashlib.sha256(text.encode()).hexdigest(),result['transcript_sha256'])
        self.assertIn(text,result['text'])

    def test_no_inference_for_unauthorized_or_invalid_requests(self):
        self.assertEqual(401,self.request({'transcript':'a'},token='wrong')[0])
        for data in ({'transcript':''},{'transcript':'x'*42001},{'transcript':4},{'transcript':'a','publish':True}):
            self.assertEqual(422,self.request(data)[0])
        self.assertEqual(0,self.provider.calls)

    def test_no_publication_route(self):
        self.assertEqual(404,self.request({},path='/v1/publish')[0])

    def test_unsubstantiated_evidence_rejected(self):
        self.assertEqual((502,{'error':'invalid_draft_evidence'}),self.request({'transcript':'bad evidence'}))
