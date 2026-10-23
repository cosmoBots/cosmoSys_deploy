"""Replaceable inference adapter; no GPU or Windows dependency."""
import json
from urllib.error import HTTPError
from urllib.request import Request, urlopen


class Ollama:
    def __init__(self, url='http://127.0.0.1:11434', model='qwen3:8b'):
        self.url, self.model = url.rstrip('/'), model

    def chat(self, payload):
        data = dict(payload, model=self.model, stream=False)
        request = Request(self.url+'/api/chat', json.dumps(data).encode(),
                          {'Content-Type':'application/json'})
        with urlopen(request, timeout=600) as response:
            return json.load(response)


class InferenceBusy(Exception):
    pass


class RemoteInference:
    """Adapter to our authenticated inference API, independent of Ollama."""
    def __init__(self, url, token):
        self.url, self.token = url.rstrip('/'), token

    def chat(self, payload):
        data = {k:v for k,v in payload.items() if k not in ('model','stream')}
        request = Request(self.url+'/v1/chat', json.dumps(data).encode(),
                          {'Content-Type':'application/json',
                           'Authorization':'Bearer '+self.token})
        try:
            with urlopen(request, timeout=620) as response:
                return json.load(response)
        except HTTPError as error:
            if error.code == 429:
                raise InferenceBusy() from None
            raise RuntimeError('Inference request failed') from None
