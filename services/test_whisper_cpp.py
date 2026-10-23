import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from whisper_cpp import WhisperCpp


class Tests(unittest.TestCase):
    def test_gpu_failure_retries_cpu(self):
        with tempfile.TemporaryDirectory() as folder:
            dependency=Path(folder)/'dependency';dependency.touch()
            provider=WhisperCpp(dependency,dependency,dependency)
            commands=[]
            def run(command,**kwargs):
                commands.append(command)
                if '-oj' in command:
                    if '-ng' not in command:return SimpleNamespace(returncode=1)
                    Path(command[command.index('-of')+1]+'.json').write_text(json.dumps({
                        'transcription':[{'offsets':{'from':100,'to':1000},'text':' prueba '}]}))
                return SimpleNamespace(returncode=0)
            with patch('whisper_cpp.subprocess.run',side_effect=run):
                self.assertEqual([{'start':.1,'end':1,'text':'prueba'}],provider.transcribe(dependency))
            self.assertEqual(3,len(commands))
            self.assertTrue(provider.last_metadata['cpu_fallback'])
