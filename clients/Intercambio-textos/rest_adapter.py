"""Native Redmine HTTP adapter for the desktop exchange client."""
import base64
import json
import os
from pathlib import Path
from urllib.parse import quote
from urllib.request import Request, urlopen


def prefix(service):
    if service not in ('cosmoSys', 'CGRol'):
        raise ValueError('Unknown service')
    return 'COSMOSYS' if service == 'cosmoSys' else 'CGROL'


def base_url(service):
    return os.environ.get(prefix(service)+'_URL', 'http://localhost:' +
                          ('3080' if service == 'cosmoSys' else '3090')).rstrip('/')


def request(service, path, data=None):
    key = prefix(service)
    secret = os.environ.get(key+'_PASSWORD_FILE')
    if not secret:
        raise ValueError('Set '+key+'_PASSWORD_FILE to a private password file.')
    password = Path(secret).read_text(encoding='utf-8').strip()
    login = os.environ.get(key+'_LOGIN', 'editor')
    auth = base64.b64encode((login+':'+password).encode()).decode()
    headers = {'Authorization': 'Basic '+auth, 'Content-Type': 'application/json'}
    raw = None if data is None else json.dumps(data).encode()
    with urlopen(Request(base_url(service)+path, data=raw, headers=headers), timeout=180) as response:
        return json.load(response)


def projects(service):
    result = []; offset = 0
    while True:
        data = request(service, f'/projects.json?limit=100&offset={offset}')
        result.extend(data['projects']); offset += len(data['projects'])
        if not data['projects'] or offset >= data['total_count']:
            return result


def server(service, project, operation, changes=None):
    path = '/projects/'+quote(project, safe='')+'/exchange/v1/'
    if operation == 'export':
        return request(service, path+'snapshot.json')
    if operation in ('check', 'apply'):
        return request(service, path+'changes.json',
                       {'changes': changes, 'dry_run': operation == 'check'})
    raise ValueError('Unknown operation')
