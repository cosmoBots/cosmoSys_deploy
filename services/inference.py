"""Replaceable inference adapter; no GPU or Windows dependency."""
import json
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
