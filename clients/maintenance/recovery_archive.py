"""Authenticated streaming backup encryption. Requires cryptography; key stays separate."""
import argparse
import os
from pathlib import Path
import tempfile
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

MAGIC = b'COSMOSYS-BACKUP-1\n'


def transform(source, target, keyfile, decrypt=False):
    source, target, keyfile = map(Path, (source, target, keyfile))
    if target.exists():
        raise ValueError('Destination already exists; refusing to overwrite.')
    if not decrypt and not keyfile.exists():
        with keyfile.open('xb') as f:
            f.write(os.urandom(32))
        os.chmod(keyfile, 0o600)
    key = keyfile.read_bytes()
    if len(key) != 32:
        raise ValueError('Expected a 32-byte recovery key.')
    fd, temporary = tempfile.mkstemp(dir=target.parent, prefix='.recovery-')
    try:
        with source.open('rb') as src, os.fdopen(fd, 'wb') as dst:
            if decrypt:
                if src.read(len(MAGIC)) != MAGIC:
                    raise ValueError('Unknown archive format.')
                nonce = src.read(12)
                remaining = source.stat().st_size - len(MAGIC) - 12 - 16
                if remaining < 0:
                    raise ValueError('Truncated archive.')
                src.seek(-16, 2)
                tag = src.read(16)
                src.seek(len(MAGIC) + 12)
                context = Cipher(algorithms.AES(key), modes.GCM(nonce, tag)).decryptor()
            else:
                nonce = os.urandom(12)
                dst.write(MAGIC + nonce)
                remaining = source.stat().st_size
                context = Cipher(algorithms.AES(key), modes.GCM(nonce)).encryptor()
            context.authenticate_additional_data(MAGIC)
            while remaining:
                chunk = src.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise ValueError('Truncated archive.')
                remaining -= len(chunk)
                dst.write(context.update(chunk))
            dst.write(context.finalize())
            if not decrypt:
                dst.write(context.tag)
            dst.flush()
            os.fsync(dst.fileno())
        # Only publish plaintext after GCM authentication succeeds; no overwrite.
        os.link(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('encrypt', 'decrypt'))
    parser.add_argument('source')
    parser.add_argument('target')
    parser.add_argument('--key', required=True)
    args = parser.parse_args()
    transform(args.source, args.target, args.key, args.mode == 'decrypt')
