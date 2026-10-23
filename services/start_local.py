"""Start configured Windows services and optionally the desktop client."""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('config',type=Path)
    parser.add_argument('--app',choices=['actas','dictado'])
    args=parser.parse_args()
    config=json.loads(args.config.read_text(encoding='utf-8'))
    env=dict(os.environ,**config['environment'],AUTHORING_SERVICES='1')
    root=Path(__file__).resolve().parent
    if config.get('ollama_executable'):
        try:
            with urlopen('http://127.0.0.1:11434/api/version',timeout=2) as response:
                json.load(response)
        except OSError:
            model_env=dict(env,OLLAMA_HOST='127.0.0.1:11434',OLLAMA_NO_CLOUD='1',
                           OLLAMA_MODELS=config['ollama_models'])
            subprocess.Popen([config['ollama_executable'],'serve'],env=model_env,
                creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0),
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            for _ in range(60):
                try:
                    with urlopen('http://127.0.0.1:11434/api/version',timeout=2) as response:json.load(response)
                    break
                except OSError:time.sleep(.5)
            else:raise RuntimeError('Configured Ollama failed to start')
    for script,port,token_name in [('inference_server.py',3130,'AI_SERVICE_TOKEN_FILE'),
        ('minutes_server.py',3131,'MINUTES_SERVICE_TOKEN_FILE'),
        ('publication_server.py',3132,'PUBLICATION_TOKEN_FILE'),
        ('transcription_server.py',3133,'TRANSCRIPTION_TOKEN_FILE')]:
        if token_name=='TRANSCRIPTION_TOKEN_FILE' and token_name not in env:
            continue
        token=Path(env[token_name]).read_text().strip()
        def healthy():
            try:
                req=Request(f'http://127.0.0.1:{port}/health',headers={'Authorization':'Bearer '+token})
                with urlopen(req,timeout=2) as response:
                    return json.load(response).get('status')=='ok'
            except OSError:return False
        if not healthy():
            process=subprocess.Popen([sys.executable,str(root/script)],env=env,
                creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            for _ in range(30):
                if process.poll() is not None:raise RuntimeError(script+' exited before startup')
                if healthy():break
                time.sleep(.2)
            else:raise RuntimeError(script+' failed readiness check')
    if args.app:
        subprocess.Popen([config['client_python'],str(Path(config['client_directory'])/(args.app+'.py'))],
            env=env,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    print('Configured local services authenticated and ready (model readiness not implied).')


if __name__=='__main__':main()
