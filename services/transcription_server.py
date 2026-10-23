"""Binary audio REST endpoint; model loading belongs to the server only."""
import argparse
import json
import os
import socket
import sys
import tempfile
import threading
from pathlib import Path
from http.server import ThreadingHTTPServer
from inference_server import handler as base_handler
from audio_archive import AudioArchive

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


def handler(provider,token,archive=None,engines=None):
    engines=dict(engines or {'faster-whisper':provider})
    gate=threading.BoundedSemaphore(1)
    class Handler(base_handler(None,token)):
        def do_GET(self):
            if self.path=='/v1/transcription-engines':
                if not self.authorized():return self.reply(401,{'error':'unauthorized'})
                return self.reply(200,{'engines':list(engines),'default':'faster-whisper',
                    'provider_checked':False})
            return super().do_GET()

        def do_POST(self):
            if not self.authorized():return self.reply(401,{'error':'unauthorized'})
            if self.path=='/v1/transcriptions/retry':return self.retry()
            if self.path!='/v1/transcriptions':return self.reply(404,{'error':'not_found'})
            engine=self.headers.get('X-Transcription-Engine','faster-whisper')
            if engine not in engines:return self.reply(422,{'error':'unknown_engine'})
            if self.headers.get('Content-Type')!='application/octet-stream':
                return self.reply(415,{'error':'binary_audio_required'})
            try:size=int(self.headers.get('Content-Length','0'))
            except ValueError:return self.reply(422,{'error':'invalid_length'})
            if not 0<size<=MAX_AUDIO or self.headers.get('Transfer-Encoding'):
                return self.reply(413,{'error':'invalid_body_size'})
            if not gate.acquire(blocking=False):return self.reply(429,{'error':'busy'})
            audio_id=None
            try:
                with tempfile.TemporaryDirectory(prefix='transcription-') as folder:
                    path=Path(folder)/'audio'
                    with path.open('wb') as file:
                        remaining=size
                        while remaining:
                            block=self.rfile.read(min(65536,remaining))
                            if not block:raise ValueError('Incomplete audio')
                            file.write(block);remaining-=len(block)
                    if archive is not None:
                        audio_id=archive.save(path)
                        segments=archive.transcribe(audio_id,engine,engines)
                    else:
                        segments=engines[engine].transcribe(str(path))
                    self.reply(200,{'segments':segments,'language':'es','review_required':True,'audio_id':audio_id,'engine':engine})
            except (ValueError,socket.timeout):self.reply(422,{'error':'invalid_audio','audio_id':audio_id})
            except Exception:self.reply(502,{'error':'transcription_failed','audio_id':audio_id})
            finally:gate.release()

        def retry(self):
            if archive is None:return self.reply(409,{'error':'archive_unavailable'})
            if self.headers.get('Content-Type')!='application/json':
                return self.reply(415,{'error':'json_required'})
            try:
                size=int(self.headers.get('Content-Length','0'))
                if not 0<size<=4096 or self.headers.get('Transfer-Encoding'):
                    return self.reply(413,{'error':'invalid_body_size'})
                data=json.loads(self.rfile.read(size))
                if not isinstance(data,dict) or set(data)!={'audio_id','engine'}:
                    raise ValueError()
                identity,engine=data['audio_id'],data['engine']
                if not isinstance(identity,str) or len(identity)!=64 or any(c not in '0123456789abcdef' for c in identity):
                    raise ValueError()
                if not isinstance(engine,str) or engine not in engines:raise ValueError()
            except (ValueError,TypeError,UnicodeError):return self.reply(422,{'error':'invalid_retry'})
            if not gate.acquire(blocking=False):return self.reply(429,{'error':'busy'})
            try:
                segments=archive.transcribe(identity,engine,engines)
                self.reply(200,{'segments':segments,'language':'es','review_required':True,
                    'audio_id':identity,'engine':engine})
            except FileNotFoundError:self.reply(404,{'error':'audio_not_found','audio_id':identity})
            except ValueError:self.reply(422,{'error':'invalid_audio','audio_id':identity})
            except Exception:self.reply(502,{'error':'transcription_failed','audio_id':identity})
            finally:gate.release()
    return Handler


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=3133)
    args=parser.parse_args()
    token=Path(os.environ['TRANSCRIPTION_TOKEN_FILE']).read_text().strip()
    if len(token)<32:raise ValueError('Token must contain at least 32 characters')
    archive=AudioArchive(os.environ.get('TRANSCRIPTION_DATA_DIR',
        str(Path(__file__).resolve().parent/'private-audio')))
    ThreadingHTTPServer(('127.0.0.1',args.port),handler(Whisper(),token,archive)).serve_forever()


if __name__=='__main__':main()
