"""Binary audio REST endpoint; model loading belongs to the server only."""
import argparse
import os
import socket
import sys
import tempfile
import threading
from pathlib import Path
from http.server import ThreadingHTTPServer
from inference_server import handler as base_handler

MAX_AUDIO=50_000_000


class Whisper:
    def __init__(self):
        self.model=None
        self.dll_handles=[]

    def transcribe(self,path):
        if self.model is None:
            if os.name=='nt':
                for directory in (Path(sys.prefix)/'Lib/site-packages/nvidia').glob('*/bin'):
                    os.environ['PATH']=str(directory)+os.pathsep+os.environ.get('PATH','')
                    self.dll_handles.append(os.add_dll_directory(str(directory)))
            from faster_whisper import WhisperModel
            self.model=WhisperModel(os.environ.get('WHISPER_MODEL','large-v3'),
                device=os.environ.get('WHISPER_DEVICE','cuda'),
                device_index=int(os.environ.get('WHISPER_DEVICE_INDEX','0')),
                compute_type=os.environ.get('WHISPER_COMPUTE_TYPE','float16'),
                download_root=os.environ.get('WHISPER_CACHE'),local_files_only=True)
        segments,info=self.model.transcribe(path,language='es',vad_filter=True)
        return [{'start':s.start,'end':s.end,'text':s.text.strip()} for s in segments]


def handler(provider,token):
    gate=threading.BoundedSemaphore(1)
    class Handler(base_handler(None,token)):
        def do_POST(self):
            if not self.authorized():return self.reply(401,{'error':'unauthorized'})
            if self.path!='/v1/transcriptions':return self.reply(404,{'error':'not_found'})
            if self.headers.get('Content-Type')!='application/octet-stream':
                return self.reply(415,{'error':'binary_audio_required'})
            try:size=int(self.headers.get('Content-Length','0'))
            except ValueError:return self.reply(422,{'error':'invalid_length'})
            if not 0<size<=MAX_AUDIO or self.headers.get('Transfer-Encoding'):
                return self.reply(413,{'error':'invalid_body_size'})
            if not gate.acquire(blocking=False):return self.reply(429,{'error':'busy'})
            try:
                with tempfile.TemporaryDirectory(prefix='transcription-') as folder:
                    path=Path(folder)/'audio'
                    with path.open('wb') as file:
                        remaining=size
                        while remaining:
                            block=self.rfile.read(min(65536,remaining))
                            if not block:raise ValueError('Incomplete audio')
                            file.write(block);remaining-=len(block)
                    segments=provider.transcribe(str(path))
                    self.reply(200,{'segments':segments,'language':'es','review_required':True})
            except (ValueError,socket.timeout):self.reply(422,{'error':'invalid_audio'})
            except Exception:self.reply(502,{'error':'transcription_failed'})
            finally:gate.release()
    return Handler


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=3133)
    args=parser.parse_args()
    token=Path(os.environ['TRANSCRIPTION_TOKEN_FILE']).read_text().strip()
    if len(token)<32:raise ValueError('Token must contain at least 32 characters')
    ThreadingHTTPServer(('127.0.0.1',args.port),handler(Whisper(),token)).serve_forever()


if __name__=='__main__':main()
