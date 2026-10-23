"""Infrastructure adapter. No database or SSH access. Only authenticated HTTP."""
import base64,json,os,urllib.request,urllib.error,urllib.parse
from pathlib import Path
BASE=os.environ.get('COSMOSYS_URL','http://localhost:3080').rstrip('/')
LOGIN=os.environ.get('COSMOSYS_LOGIN','editor')
SECRET_FILE=os.environ.get('COSMOSYS_PASSWORD_FILE','')
ALLOWED_LOGINS=os.environ.get('COSMOSYS_ALLOWED_LOGINS',LOGIN).split(',')

def service_password():
    if not SECRET_FILE:raise ValueError('Set COSMOSYS_PASSWORD_FILE to a private password file.')
    return Path(SECRET_FILE).read_text(encoding='utf-8').strip()


def authenticate(login,password):
    if login not in ALLOWED_LOGINS:raise ValueError('Usuario no habilitado en este gestor local.')
    headers={'Authorization':'Basic '+base64.b64encode((login+':'+password).encode()).decode(),'Accept':'application/json'}
    try:
        with urllib.request.urlopen(urllib.request.Request(BASE+'/users/current.json',headers=headers),timeout=20) as response:
            user=json.load(response)['user']
            if user['login']!=login:raise ValueError('Identidad incorrecta.')
    except urllib.error.HTTPError:raise ValueError('Usuario o contraseña de cosmoSys incorrectos.') from None
    return login

def request(path,data=None):
    password=service_password()
    headers={'Authorization':'Basic '+base64.b64encode((LOGIN+':'+password).encode()).decode(),'Accept':'application/json'}
    raw=None
    if data is not None:raw=json.dumps(data,ensure_ascii=False).encode();headers['Content-Type']='application/json'
    try:
        with urllib.request.urlopen(urllib.request.Request(BASE+path,data=raw,headers=headers),timeout=180) as response:return json.load(response)
    except urllib.error.HTTPError as error:
        try:detail=json.loads(error.read()).get('error','Operación rechazada por cosmoSys.')
        except Exception:detail='Operación rechazada por cosmoSys.'
        raise ValueError(f'cosmoSys ({error.code}): {detail}') from None

def endpoint(project,resource):return '/projects/'+urllib.parse.quote(project,safe='')+'/exchange/v1/'+resource+'.json'
def projects(_service=None):
    result=[];offset=0
    while True:
        data=request(f'/projects.json?limit=100&offset={offset}');result.extend(data['projects']);offset+=len(data['projects'])
        if offset>=data['total_count'] or not data['projects']:return result
def server(service,project,operation,changes=None):
    if service!='cosmoSys':raise ValueError('Este gestor solo conecta con cosmoSys.')
    if operation=='export':return request(endpoint(project,'snapshot'))
    if operation in ('check','apply'):return request(endpoint(project,'changes'),dict(changes=changes,dry_run=operation=='check'))
    raise ValueError('Operación desconocida.')
def create_node(project,title,parent,token,dry_run=False,template=''):
    return request(endpoint(project,'nodes'),dict(title=title,parent=int(parent.split(':')[1]) if parent else None,token=token,dry_run=dry_run,template=template))

def snapshot(project):
    data=server('cosmoSys',project,'export');data.update(format=1,service='cosmoSys')
    for record in data['records']:
        record['fields']={k:v.replace('\r\n','\n').replace('\r','\n') for k,v in record['fields'].items()}
    return data
