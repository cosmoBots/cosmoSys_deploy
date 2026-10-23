import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
import wave
import dictado


class DictationTests(unittest.TestCase):
    def test_capture_to_wave_without_live_microphone(self):
        class Stream:
            def __init__(self, **kwargs):
                self.callback = kwargs['callback']
            def start(self):
                self.callback(b'\0\0' * 4800, 4800, None, False)
            def stop(self):
                pass
            def close(self):
                pass
        with tempfile.TemporaryDirectory() as folder:
            with patch('sounddevice.query_devices', return_value={'default_samplerate': 48000}), patch('sounddevice.RawInputStream', Stream):
                recorder = dictado.Recorder(); recorder.start(0)
                path = recorder.stop(Path(folder) / 'test.wav')
            with wave.open(path) as audio:
                self.assertEqual(audio.getnframes(), 4800)
                self.assertEqual(audio.getnchannels(), 1)
                self.assertEqual(audio.getframerate(), 48000)
            self.assertIsNone(recorder.stream)

    def test_publication_retry_does_not_duplicate(self):
        pages = {}; writes = []
        def api(service, path, data=None):
            if data:
                pages[path] = data['wiki_page']['text']; writes.append(path); return
            if path not in pages:
                raise HTTPError(path, 404, 'missing', {}, None)
            return {'wiki_page': {'text': pages[path]}}
        with patch.object(dictado.actas, 'project_api', api):
            first = dictado.publish('cosmoSys', 'demo', 'Texto revisado', 'sesion')
            second = dictado.publish('cosmoSys', 'demo', 'Texto revisado', 'sesion')
            self.assertEqual(first, second)
            self.assertEqual(len(writes), 1)
            pages[writes[0]] = 'Editado en Redmine'
            with self.assertRaises(ValueError):
                dictado.publish('cosmoSys', 'demo', 'Texto revisado', 'sesion')

    def test_reviewed_text_and_original_are_distinct(self):
        content = dictado.build_content('Una nota', 'Corregido <texto>', 'Original', 'Nota de universo')
        self.assertIn('Corregido &lt;texto&gt;', content)
        self.assertIn('Original', content)
        with self.assertRaises(ValueError):
            dictado.build_content('', 'texto', '', 'Nota')


if __name__ == '__main__':
    unittest.main()
