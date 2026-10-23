"""Review-bound publication; adapters own destination-specific behavior."""
import hashlib
import hmac
import json
import secrets
import threading
import time
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


class Conflict(Exception):
    pass


class RedmineWiki:
    def __init__(self, url, api_key):
        self.url, self.api_key = url.rstrip('/'), api_key

    def request(self, path, data=None):
        req=Request(self.url+path, None if data is None else json.dumps(data).encode(),
                    {'X-Redmine-API-Key':self.api_key,'Content-Type':'application/json'},
                    method='GET' if data is None else 'PUT')
        with urlopen(req,timeout=30) as response:
            raw=response.read()
            return json.loads(raw) if raw else {}

    def publish(self, project, page, text):
        path='/projects/'+quote(project,safe='')+'/wiki/'+quote(page,safe='')
        try:
            existing=self.request(path+'.json')['wiki_page']['text']
        except HTTPError as error:
            if error.code!=404: raise
        else:
            if existing != text: raise Conflict('Destination has different content')
            return {'url':self.url+path,'reused':True}
        self.request(path+'.json',{'wiki_page':{'text':text,'comments':'Reviewed publication'}})
        if self.request(path+'.json')['wiki_page']['text'] != text:
            raise Conflict('Publication verification failed')
        return {'url':self.url+path,'reused':False}


class Publisher:
    def __init__(self, destinations):
        self.destinations=destinations
        self.pending={}
        self.lock=threading.Lock()

    def preview(self, data):
        if not isinstance(data,dict) or set(data)!={'destination','project','text','request_id'}:
            raise ValueError('Invalid fields')
        if any(not isinstance(v,str) or not v.strip() for v in data.values()):
            raise ValueError('Text fields required')
        if len(data['text'])>42000 or len(data['request_id'])>200 or len(data['project'])>200:
            raise ValueError('Input too large')
        if data['destination'] not in self.destinations: raise ValueError('Unknown destination')
        adapter, projects=self.destinations[data['destination']]
        if data['project'] not in projects: raise ValueError('Project not enabled')
        identity=json.dumps([data['destination'],data['project'],data['request_id']],ensure_ascii=False).encode()
        page='Publication_'+hashlib.sha256(identity).hexdigest()
        digest=hashlib.sha256(data['text'].encode()).hexdigest()
        token=secrets.token_urlsafe(32)
        with self.lock:
            self.pending={k:v for k,v in self.pending.items() if v[0]>time.time()}
            if len(self.pending)>=100: raise ValueError('Too many pending reviews')
            self.pending[token]=(time.time()+1800,dict(data),page,digest)
        return dict(data,page=page,review_token=token,content_sha256=digest,expires_in=1800)

    def commit(self, data):
        if not isinstance(data,dict) or set(data)!={'review_token','content_sha256','confirmed'} or data['confirmed'] is not True:
            raise ValueError('Explicit review confirmation required')
        if not isinstance(data['review_token'],str) or not isinstance(data['content_sha256'],str):
            raise ValueError('Invalid review')
        with self.lock:
            item=self.pending.get(data['review_token'])
            if not item or item[0]<time.time(): raise Conflict('Review expired')
            _,payload,page,digest=item
            if not hmac.compare_digest(digest,data['content_sha256']): raise Conflict('Content changed')
            adapter,_=self.destinations[payload['destination']]
            return adapter.publish(payload['project'],page,payload['text'])
