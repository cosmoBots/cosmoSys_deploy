"""Adapter for explicitly configured local whisper.cpp and FFmpeg binaries."""
import json
import subprocess
import tempfile
from pathlib import Path


class WhisperCpp:
    def __init__(self, executable, model, ffmpeg, device='auto'):
        self.executable,self.model,self.ffmpeg=map(str,(executable,model,ffmpeg))
        if device not in ('auto','cpu','gpu'):raise ValueError('Invalid device')
        self.device=device
        self.last_metadata={}
        for path in (executable,model,ffmpeg):
            if not Path(path).is_file():raise ValueError('Missing configured transcription dependency')

    def transcribe(self,path):
        flags=getattr(subprocess,'CREATE_NO_WINDOW',0)
        with tempfile.TemporaryDirectory(prefix='whisper-cpp-') as folder:
            wav=Path(folder)/'input.wav';output=Path(folder)/'result'
            conversion=subprocess.run([self.ffmpeg,'-nostdin','-v','error','-y','-i',str(path),
                '-ar','16000','-ac','1','-c:a','pcm_s16le',str(wav)],
                capture_output=True,timeout=120,creationflags=flags)
            if conversion.returncode:raise ValueError('Audio conversion failed')
            command=[self.executable,'-m',self.model,'-f',str(wav),'-l','es','-oj','-of',str(output)]
            cpu=self.device=='cpu'
            result=subprocess.run(command+(['-ng'] if cpu else []),capture_output=True,timeout=1500,creationflags=flags)
            fallback=False
            if result.returncode and self.device=='auto':
                fallback=True;cpu=True
                result=subprocess.run(command+['-ng'],capture_output=True,timeout=1500,creationflags=flags)
            if result.returncode:raise RuntimeError('whisper.cpp failed')
            data=json.loads(output.with_suffix('.json').read_text(encoding='utf-8'))
            self.last_metadata={'model':Path(self.model).name,'device_request':self.device,
                'cpu_forced':cpu,'cpu_fallback':fallback}
            return [{'start':s['offsets']['from']/1000,'end':s['offsets']['to']/1000,
                     'text':s['text'].strip()} for s in data['transcription']]
