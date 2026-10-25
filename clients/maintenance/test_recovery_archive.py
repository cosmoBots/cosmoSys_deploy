import tempfile
import unittest
from pathlib import Path
from cryptography.exceptions import InvalidTag
from recovery_archive import transform


class RecoveryTest(unittest.TestCase):
    def test_roundtrip_tamper_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            src, enc, key, restored = [root / n for n in ('src', 'enc', 'key', 'restored')]
            src.write_bytes(b'private backup\x00' * 100000)
            transform(src, enc, key)
            transform(enc, restored, key, True)
            self.assertEqual(src.read_bytes(), restored.read_bytes())
            with self.assertRaises(ValueError):
                transform(enc, restored, key, True)
            corrupt = bytearray(enc.read_bytes()); corrupt[-20] ^= 1
            enc.write_bytes(corrupt)
            with self.assertRaises(InvalidTag):
                transform(enc, root / 'invalid', key, True)
            self.assertFalse((root / 'invalid').exists())
            self.assertFalse(list(root.glob('.recovery-*')))
