import unittest
import json
import threading
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from publication_server import handler
from publication import Publisher, Conflict


class FakeDestination:
    def __init__(self): self.pages={};self.writes=0
    def publish(self,project,page,text):
        key=(project,page)
        if key in self.pages:
            if self.pages[key]!=text: raise Conflict()
            return {'reused':True}
        self.pages[key]=text;self.writes+=1
        return {'reused':False}


class Tests(unittest.TestCase):
    def setUp(self):
        self.destination=FakeDestination()
        self.publisher=Publisher({'cosmosys':(self.destination,{'demo'})})
        self.payload=dict(destination='cosmosys',project='demo',text='Reviewed text',request_id='one')

    def commit(self,preview,**extra):
        return self.publisher.commit(dict(review_token=preview['review_token'],
            content_sha256=preview['content_sha256'],confirmed=True,**extra))

    def test_preview_has_no_side_effect_and_retry_is_stable(self):
        preview=self.publisher.preview(self.payload)
        self.assertEqual(0,self.destination.writes)
        self.commit(preview);self.commit(preview)
        restarted=Publisher({'cosmosys':(self.destination,{'demo'})})
        p=restarted.preview(self.payload)
        restarted.commit(dict(review_token=p['review_token'],content_sha256=p['content_sha256'],confirmed=True))
        self.assertEqual(1,self.destination.writes)

    def test_changed_content_with_same_identity_conflicts(self):
        self.commit(self.publisher.preview(self.payload))
        with self.assertRaises(Conflict):
            self.commit(self.publisher.preview(dict(self.payload,text='Different')))

    def test_confirmation_and_allowlist_required(self):
        p=self.publisher.preview(self.payload)
        with self.assertRaises(ValueError):
            self.publisher.commit(dict(review_token=p['review_token'],content_sha256=p['content_sha256'],confirmed=False))
        with self.assertRaises(ValueError):
            self.publisher.preview(dict(self.payload,project='private'))
        self.assertEqual(0,self.destination.writes)

    def test_hash_and_expiry_checked(self):
        p=self.publisher.preview(self.payload)
        with self.assertRaises(Conflict):
            self.publisher.commit(dict(review_token=p['review_token'],content_sha256='wrong',confirmed=True))
        item=self.publisher.pending[p['review_token']]
        self.publisher.pending[p['review_token']]=(0,*item[1:])
        with self.assertRaises(Conflict): self.commit(p)

    def test_authenticated_http_preview_commit(self):
        server=ThreadingHTTPServer(('127.0.0.1',0),handler(self.publisher,'p'*32))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        def post(path,data,token='p'*32):
            connection=HTTPConnection('127.0.0.1',server.server_port,timeout=3)
            connection.request('POST',path,json.dumps(data),{'Content-Type':'application/json','Authorization':'Bearer '+token})
            response=connection.getresponse();result=response.status,json.loads(response.read())
            connection.close();return result
        try:
            path='/v1/publications/'
            self.assertEqual(401,post(path+'preview',self.payload,'wrong')[0])
            status,p=post(path+'preview',self.payload)
            self.assertEqual(200,status);self.assertEqual(0,self.destination.writes)
            status,result=post(path+'commit',dict(review_token=p['review_token'],content_sha256=p['content_sha256'],confirmed=True))
            self.assertEqual(200,status);self.assertEqual(1,self.destination.writes)
        finally:
            server.shutdown();server.server_close();thread.join()
