"""Client of the separated services; never reads model or Redmine credentials."""
import hashlib
import json
import os
from pathlib import Path
from urllib.request import Request, urlopen


def call(service, path, data):
    port = 3131 if service == 'MINUTES' else 3132
    url = os.environ.get(service+'_URL',f'http://127.0.0.1:{port}').rstrip('/')
    token_var = 'MINUTES_SERVICE_TOKEN_FILE' if service == 'MINUTES' else 'PUBLICATION_TOKEN_FILE'
    token = Path(os.environ[token_var]).read_text(encoding='utf-8').strip()
    request = Request(url+path,json.dumps(data).encode(),
                      {'Content-Type':'application/json','Authorization':'Bearer '+token})
    with urlopen(request,timeout=650) as response:
        return json.load(response)


def minutes(text):
    return call('MINUTES','/v1/minutes/draft',{'transcript':text})['text']


def transcribe(filename,engine='faster-whisper',include_metadata=False):
    path=Path(filename)
    if not 0<path.stat().st_size<=50_000_000:
        raise ValueError('El audio debe ocupar entre 1 y 50.000.000 bytes.')
    audio=path.read_bytes()
    token=Path(os.environ['TRANSCRIPTION_TOKEN_FILE']).read_text().strip()
    url=os.environ.get('TRANSCRIPTION_URL','http://127.0.0.1:3133').rstrip('/')
    request=Request(url+'/v1/transcriptions',audio,{'Content-Type':'application/octet-stream',
                    'Authorization':'Bearer '+token,'X-Transcription-Engine':engine})
    with urlopen(request,timeout=1800) as response:
        result=json.load(response)
        return result if include_metadata else result['segments']


def transcription_engines():
    return transcription_request('/v1/transcription-engines')


def retry_transcription(audio_id,engine):
    return transcription_request('/v1/transcriptions/retry',{'audio_id':audio_id,'engine':engine})


def transcription_request(path,data=None):
    token=Path(os.environ['TRANSCRIPTION_TOKEN_FILE']).read_text().strip()
    url=os.environ.get('TRANSCRIPTION_URL','http://127.0.0.1:3133').rstrip('/')
    request=Request(url+path,None if data is None else json.dumps(data).encode(),
        {'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    with urlopen(request,timeout=1800) as response:return json.load(response)


def publish_reviewed(service, project, content, request_id):
    destination = {'cosmoSys':'cosmosys','CGRol':'cgrol'}[service]
    preview = call('PUBLICATION','/v1/publications/preview',dict(
        destination=destination,project=project,text=content,request_id=request_id))
    digest = hashlib.sha256(content.encode()).hexdigest()
    if (preview['text'] != content or preview['content_sha256'] != digest
        or preview['destination'] != destination or preview['project'] != project):
        raise ValueError('Publication preview differs from reviewed content')
    return call('PUBLICATION','/v1/publications/commit',dict(
        review_token=preview['review_token'],content_sha256=digest,confirmed=True))['url']
