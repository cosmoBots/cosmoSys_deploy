import tempfile
import unittest
from pathlib import Path
from audio_archive import AudioArchive


class Engine:
    def __init__(self, fail=False): self.fail = fail
    def transcribe(self, path):
        if self.fail: raise RuntimeError('engine unavailable')
        return [{'start': 0, 'end': 1, 'text': Path(path).read_text()}]


class ArchiveTests(unittest.TestCase):
    def test_failure_restart_and_different_engine_preserve_original_and_history(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source.wav'
            source.write_bytes(b'synthetic')
            root = Path(folder) / 'archive'
            archive = AudioArchive(root)
            identity = archive.save(source)
            self.assertEqual(identity, archive.save(source))
            source.unlink()
            with self.assertRaises(RuntimeError):
                archive.transcribe(identity, 'first', {'first': Engine(True)})
            archive = AudioArchive(root)
            result = archive.transcribe(identity, 'second', {'second': Engine()})
            self.assertEqual('synthetic', result[0]['text'])
            with archive.connect() as db:
                self.assertEqual(1, db.execute('SELECT count(*) FROM audio').fetchone()[0])
                self.assertEqual([('first', 'failed'), ('second', 'complete')],
                    db.execute('SELECT engine,status FROM attempts ORDER BY rowid').fetchall())
            (root / (identity + '.audio')).write_bytes(b'corrupted')
            with self.assertRaises(ValueError):
                archive.transcribe(identity, 'second', {'second': Engine()})
            with self.assertRaises(ValueError):
                archive.transcribe('../source', 'second', {'second': Engine()})
