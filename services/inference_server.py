"""Authenticated loopback inference API. Run separately from the authoring apps."""
import argparse
import hmac
import json
import os
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from inference import Ollama

MAX_BODY = 200_000


def handler(provider, token):
    gate = threading.BoundedSemaphore(1)

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(15)

        def log_message(self, *args):
            pass

        def reply(self, status, value):
            raw = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(raw)

        def authorized(self):
            return hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer '+token)

        def do_GET(self):
            if not self.authorized():
                return self.reply(401, {'error':'unauthorized'})
            if self.path == '/health':
                return self.reply(200, {'status':'ok', 'api_version':'1',
                                        'provider_checked':False})
            self.reply(404, {'error':'not_found'})

        def do_POST(self):
            if not self.authorized():
                return self.reply(401, {'error':'unauthorized'})
            if self.path != '/v1/chat':
                return self.reply(404, {'error':'not_found'})
            if self.headers.get('Content-Type','').split(';')[0] != 'application/json':
                return self.reply(415, {'error':'json_required'})
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= MAX_BODY or self.headers.get('Transfer-Encoding'):
                    return self.reply(413, {'error':'invalid_body_size'})
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict) or set(payload)-{'messages','format','options','think'}:
                    raise ValueError()
                messages = payload.get('messages')
                if not isinstance(messages,list) or not 1 <= len(messages) <= 100:
                    raise ValueError()
                for message in messages:
                    if (not isinstance(message,dict) or set(message) != {'role','content'}
                        or message['role'] not in ('system','user','assistant')
                        or not isinstance(message['content'],str)):
                        raise ValueError()
                if 'options' in payload:
                    options = payload['options']
                    if not isinstance(options,dict) or set(options)-{'temperature','num_ctx','num_predict'}:
                        raise ValueError()
                    for key, maximum in [('temperature',2),('num_ctx',32768),('num_predict',4096)]:
                        if key in options and (type(options[key]) not in (int,float) or not 0 <= options[key] <= maximum):
                            raise ValueError()
                if 'think' in payload and type(payload['think']) is not bool:
                    raise ValueError()
                if 'format' in payload and not (isinstance(payload['format'],dict) or payload['format']=='json'):
                    raise ValueError()
            except (ValueError, TypeError, socket.timeout):
                return self.reply(422, {'error':'invalid_request'})
            if not gate.acquire(blocking=False):
                return self.reply(429, {'error':'busy'})
            try:
                result = provider.chat(payload)
                if not isinstance(result.get('message',{}).get('content'),str):
                    raise ValueError('Invalid provider response')
                self.reply(200, result)
            except Exception:
                self.reply(502, {'error':'provider_failed'})
            finally:
                gate.release()
    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=3130)
    args = parser.parse_args()
    token = Path(os.environ['AI_SERVICE_TOKEN_FILE']).read_text(encoding='utf-8').strip()
    if len(token) < 32:
        raise ValueError('Token must contain at least 32 characters')
    provider = Ollama(os.environ.get('OLLAMA_URL','http://127.0.0.1:11434'),
                      os.environ.get('OLLAMA_MODEL','qwen3:8b'))
    ThreadingHTTPServer(('127.0.0.1',args.port),handler(provider,token)).serve_forever()


if __name__ == '__main__':
    main()
