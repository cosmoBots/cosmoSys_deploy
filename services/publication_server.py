"""Loopback publication API; destinations are administrator-configured."""
import argparse
import json
import os
import socket
from pathlib import Path
from http.server import ThreadingHTTPServer
from inference_server import handler as base_handler, MAX_BODY
from publication import Publisher, RedmineWiki, Conflict


def handler(publisher,token):
    class Handler(base_handler(None,token)):
        def do_POST(self):
            if not self.authorized(): return self.reply(401,{'error':'unauthorized'})
            routes={'/v1/publications/preview':publisher.preview,'/v1/publications/commit':publisher.commit}
            if self.path not in routes: return self.reply(404,{'error':'not_found'})
            if self.headers.get('Content-Type','').split(';')[0]!='application/json':
                return self.reply(415,{'error':'json_required'})
            try:
                size=int(self.headers.get('Content-Length','0'))
                if not 0<size<=MAX_BODY or self.headers.get('Transfer-Encoding'):
                    return self.reply(413,{'error':'invalid_body_size'})
                data=json.loads(self.rfile.read(size))
                result=routes[self.path](data)
                self.reply(200,result)
            except Conflict:
                self.reply(409,{'error':'publication_conflict'})
            except (ValueError,TypeError,KeyError,socket.timeout):
                self.reply(422,{'error':'invalid_request_or_review'})
            except Exception:
                self.reply(502,{'error':'destination_failed'})
    return Handler


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--port',type=int,default=3132)
    args=parser.parse_args()
    token=Path(os.environ['PUBLICATION_TOKEN_FILE']).read_text().strip()
    if len(token)<32: raise ValueError('Token must contain at least 32 characters')
    config=json.loads(Path(os.environ['PUBLICATION_CONFIG_FILE']).read_text(encoding='utf-8'))
    destinations={}
    for name,entry in config.items():
        if entry['adapter']!='redmine-wiki': raise ValueError('Unsupported adapter')
        key=Path(entry['api_key_file']).read_text().strip()
        if not key or not isinstance(entry['projects'],list): raise ValueError('Invalid destination')
        destinations[name]=(RedmineWiki(entry['url'],key),set(entry['projects']))
    ThreadingHTTPServer(('127.0.0.1',args.port),handler(Publisher(destinations),token)).serve_forever()


if __name__=='__main__': main()
