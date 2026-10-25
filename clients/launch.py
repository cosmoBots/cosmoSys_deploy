"""Launch an installed client with an explicit private environment configuration."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('client', choices=('intercambio', 'historias', 'academico'))
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--serve', action='store_true')
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding='utf-8-sig'))
    environment = config.get('environment')
    if not isinstance(environment, dict) or any(
            not isinstance(k, str) or not isinstance(v, str)
            for k, v in environment.items()):
        raise ValueError('Configuration requires a string environment mapping.')
    root = Path(__file__).resolve().parent
    if args.client == 'intercambio':
        if args.serve:
            parser.error('--serve only applies to web managers')
        command = [sys.executable, str(root / 'Intercambio-textos' / 'app.py')]
    else:
        command = [sys.executable, str(root / 'Gestores' / 'server.py'), args.client]
        if args.serve:
            command.append('--serve')
    result = subprocess.run(command, env=dict(os.environ, **environment), cwd=root)
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
