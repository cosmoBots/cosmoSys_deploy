"""Persistent originals and append-only transcription attempts, independent of engine."""
import hashlib
import json
import os
import shutil
import sqlite3
import uuid
from contextlib import contextmanager
from pathlib import Path


class AudioArchive:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS audio (
                    id TEXT PRIMARY KEY, bytes INTEGER NOT NULL,
                    created TEXT DEFAULT CURRENT_TIMESTAMP);
                CREATE TABLE IF NOT EXISTS attempts (
                    id TEXT PRIMARY KEY, audio_id TEXT NOT NULL, engine TEXT NOT NULL,
                    status TEXT NOT NULL, result TEXT,
                    created TEXT DEFAULT CURRENT_TIMESTAMP);
            ''')

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.root / 'archive.sqlite3')
        try:
            with db:
                yield db
        finally:
            db.close()

    def save(self, source):
        digest = hashlib.sha256()
        with open(source, 'rb') as stream:
            for chunk in iter(lambda: stream.read(65536), b''):
                digest.update(chunk)
        identity = digest.hexdigest()
        target = self.root / (identity + '.audio')
        if not target.exists():
            temporary = self.root / (uuid.uuid4().hex + '.part')
            try:
                with open(source, 'rb') as src, temporary.open('wb') as dst:
                    shutil.copyfileobj(src, dst)
                    dst.flush()
                    os.fsync(dst.fileno())
                os.replace(temporary, target)
            finally:
                temporary.unlink(missing_ok=True)
        with self.connect() as db:
            db.execute('INSERT OR IGNORE INTO audio(id,bytes) VALUES (?,?)',
                       (identity, target.stat().st_size))
        return identity

    def transcribe(self, identity, engine, engines):
        # Only registered engines and content IDs; never accept paths from callers.
        if len(identity) != 64 or any(c not in '0123456789abcdef' for c in identity):
            raise ValueError('Invalid audio identity')
        provider = engines[engine]
        path = self.root / (identity + '.audio')
        if hashlib.sha256(path.read_bytes()).hexdigest() != identity:
            raise ValueError('Audio integrity check failed')
        attempt = uuid.uuid4().hex
        with self.connect() as db:
            db.execute('INSERT INTO attempts(id,audio_id,engine,status) VALUES (?,?,?,?)',
                       (attempt, identity, engine, 'running'))
        try:
            result = provider.transcribe(str(path))
            encoded = json.dumps(result, ensure_ascii=False)
        except Exception:
            with self.connect() as db:
                db.execute('UPDATE attempts SET status=? WHERE id=?', ('failed', attempt))
            raise
        with self.connect() as db:
            db.execute('UPDATE attempts SET status=?,result=? WHERE id=?',
                       ('complete', encoded, attempt))
        return result
