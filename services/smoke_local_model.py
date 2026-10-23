"""Explicit smoke test: real local Ollama, synthetic text, in-memory publication."""
import sys
import threading
from pathlib import Path
from http.server import ThreadingHTTPServer
from unittest.mock import patch
import os
import tempfile
from inference import Ollama, RemoteInference
from inference_server import handler as inference_handler
from minutes_server import handler as minutes_handler
from publication_server import handler as publication_handler
from minutes import Minutes
from publication import Publisher, Conflict

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'clients'/'IA-local'))
import service_client


class Destination:
    def __init__(self): self.pages={}
    def publish(self,project,page,text):
        if page in self.pages and self.pages[page]!=text: raise Conflict()
        self.pages[page]=text
        return {'url':'https://example.invalid/'+page}


def main():
    token='synthetic-test-token-not-for-production'
    destination=Destination()
    inference=ThreadingHTTPServer(('127.0.0.1',0),inference_handler(Ollama(),token))
    minutes=ThreadingHTTPServer(('127.0.0.1',0),minutes_handler(Minutes(RemoteInference(
        f'http://127.0.0.1:{inference.server_port}',token)),token))
    publication=ThreadingHTTPServer(('127.0.0.1',0),publication_handler(
        Publisher({'cosmosys':(destination,{'synthetic'})}),token))
    servers=[inference,minutes,publication]
    for server in servers:
        threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        with tempfile.TemporaryDirectory() as tmp:
            secret=Path(tmp)/'token';secret.write_text(token)
            with patch.dict(os.environ,{'MINUTES_URL':f'http://127.0.0.1:{minutes.server_port}',
                'PUBLICATION_URL':f'http://127.0.0.1:{publication.server_port}',
                'MINUTES_SERVICE_TOKEN_FILE':str(secret),'PUBLICATION_TOKEN_FILE':str(secret)}):
                draft=service_client.minutes('Ana: Decidimos revisar el documento. Luis: Yo enviaré el informe mañana.')
                assert 'Borrador' in draft
                for _ in range(2):
                    service_client.publish_reviewed('cosmoSys','synthetic',draft,'smoke-1')
                assert len(destination.pages)==1
                print('PASS: client -> minutes REST -> inference REST -> real Ollama; publication REST -> simulated destination, retry verified.')
    finally:
        for server in servers: server.shutdown();server.server_close()


if __name__=='__main__': main()
