"""Meeting-draft REST service. No publication or direct model dependency."""
import argparse
import hashlib
import json
import os
import socket
import threading
from pathlib import Path
from http.server import ThreadingHTTPServer
from inference_server import handler as authenticated_handler, MAX_BODY
from inference import RemoteInference, InferenceBusy
from minutes import Minutes


def handler(engine, token):
    base = authenticated_handler(None, token)
    gate = threading.BoundedSemaphore(1)

    class Handler(base):
        def do_POST(self):
            if not self.authorized():
                return self.reply(401, {'error':'unauthorized'})
            if self.path != '/v1/minutes/draft':
                return self.reply(404, {'error':'not_found'})
            if self.headers.get('Content-Type','').split(';')[0] != 'application/json':
                return self.reply(415, {'error':'json_required'})
            try:
                length = int(self.headers.get('Content-Length','0'))
                if not 0 < length <= MAX_BODY or self.headers.get('Transfer-Encoding'):
                    return self.reply(413, {'error':'invalid_body_size'})
                data = json.loads(self.rfile.read(length))
                if not isinstance(data,dict) or set(data) != {'transcript'}:
                    raise ValueError()
                text = data['transcript']
                if not isinstance(text,str) or not text.strip() or len(text)>42000:
                    raise ValueError()
            except (ValueError,TypeError,socket.timeout):
                return self.reply(422, {'error':'invalid_transcript'})
            if not gate.acquire(blocking=False):
                return self.reply(429, {'error':'busy'})
            try:
                draft = engine.draft(text)
                self.reply(200, {'status':'draft','review_required':True,
                                 'transcript_sha256':hashlib.sha256(text.encode()).hexdigest(),
                                 'text':draft})
            except InferenceBusy:
                self.reply(429, {'error':'inference_busy'})
            except (ValueError,KeyError,TypeError,AttributeError):
                self.reply(502, {'error':'invalid_draft_evidence'})
            except Exception:
                self.reply(502, {'error':'inference_failed'})
            finally:
                gate.release()
    return Handler


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--port',type=int,default=3131)
    args=parser.parse_args()
    token=Path(os.environ['MINUTES_SERVICE_TOKEN_FILE']).read_text(encoding='utf-8').strip()
    upstream=Path(os.environ['AI_SERVICE_TOKEN_FILE']).read_text(encoding='utf-8').strip()
    if min(len(token),len(upstream))<32:
        raise ValueError('Tokens must contain at least 32 characters')
    engine=Minutes(RemoteInference(os.environ.get('INFERENCE_URL','http://127.0.0.1:3130'),upstream))
    ThreadingHTTPServer(('127.0.0.1',args.port),handler(engine,token)).serve_forever()


if __name__=='__main__':
    main()
