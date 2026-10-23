import json
import threading
import unittest
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from inference_server import handler


class Provider:
    def __init__(self): self.calls = 0
    def chat(self, payload):
        self.calls += 1
        if payload['messages'][0]['content']=='fail':
            raise RuntimeError('private provider details')
        return {'message':{'content':'test result'}}


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.provider=Provider()
        self.server=ThreadingHTTPServer(('127.0.0.1',0),handler(self.provider,'t'*32))
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()

    def request(self,payload,authorized=True):
        connection=HTTPConnection('127.0.0.1',self.server.server_port,timeout=3)
        headers={'Content-Type':'application/json'}
        if authorized: headers['Authorization']='Bearer '+'t'*32
        connection.request('POST','/v1/chat',json.dumps(payload),headers)
        response=connection.getresponse(); result=(response.status,json.loads(response.read()))
        connection.close(); return result

    def test_auth_precedes_inference(self):
        self.assertEqual(401,self.request({},False)[0])
        self.assertEqual(0,self.provider.calls)

    def test_provider_contract(self):
        status,result=self.request({'messages':[{'role':'user','content':'hello'}]})
        self.assertEqual(200,status)
        self.assertEqual('test result',result['message']['content'])

    def test_invalid_request_does_not_invoke_provider(self):
        for payload in ({}, {'messages':[]}, {'messages':[{'role':'tool','content':'x'}]},
                        {'messages':[{'role':'user','content':'x'}],'model':'override'}):
            self.assertEqual(422,self.request(payload)[0])
        self.assertEqual(0,self.provider.calls)

    def test_provider_error_is_redacted(self):
        self.assertEqual((502,{'error':'provider_failed'}),self.request(
            {'messages':[{'role':'user','content':'fail'}]}))
