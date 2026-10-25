import sqlite3,json
from contextlib import contextmanager

class Store:
    def __init__(self,path):
        self.path=path
        with self.db() as db:
            db.executescript('''CREATE TABLE IF NOT EXISTS works(id TEXT PRIMARY KEY, project TEXT NOT NULL, root TEXT NOT NULL, title TEXT NOT NULL, UNIQUE(project,root));
            CREATE TABLE IF NOT EXISTS notes(work TEXT NOT NULL,node TEXT NOT NULL,data TEXT NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(work,node));''')
            if 'storage' not in {r['name'] for r in db.execute('PRAGMA table_info(works)')}:
                db.execute("ALTER TABLE works ADD COLUMN storage TEXT NOT NULL DEFAULT 'cosmosys'")
            db.execute('''CREATE TABLE IF NOT EXISTS document_nodes(
                work TEXT NOT NULL,key TEXT NOT NULL,parent TEXT,position INTEGER NOT NULL,
                subject TEXT NOT NULL,description TEXT NOT NULL,revision INTEGER NOT NULL,
                PRIMARY KEY(work,key))''')
    @contextmanager
    def db(self):
        db=sqlite3.connect(self.path,timeout=20)
        db.row_factory=sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()
    def works(self):
        with self.db() as db:return [dict(r) for r in db.execute('SELECT * FROM works ORDER BY title,id')]
    def work(self,key):
        with self.db() as db:r=db.execute('SELECT * FROM works WHERE id=?',(key,)).fetchone()
        if not r:raise ValueError('Trabajo no encontrado.')
        return dict(r)
    def add(self,token,project,root,title):
        with self.db() as db:
            old=db.execute('SELECT * FROM works WHERE project=? AND root=?',(project,root)).fetchone()
            if old:return dict(old)
            db.execute('INSERT INTO works(id,project,root,title) VALUES(?,?,?,?)',(token,project,root,title))
        return self.work(token)
    def notes(self,work):
        with self.db() as db:return {r['node']:{'data':json.loads(r['data']),'revision':r['revision']} for r in db.execute('SELECT * FROM notes WHERE work=?',(work,))}
    def save_notes(self,work,node,data,revision):
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT * FROM notes WHERE work=? AND node=?',(work,node)).fetchone()
            if old and json.loads(old['data'])==data:return old['revision']
            if (old['revision'] if old else 0)!=revision:raise ValueError('Las notas cambiaron. Vuelve a cargar el trabajo antes de guardarlas.')
            new=revision+1
            db.execute('INSERT INTO notes VALUES(?,?,?,?) ON CONFLICT(work,node) DO UPDATE SET data=excluded.data,revision=excluded.revision',(work,node,json.dumps(data,ensure_ascii=False),new))
            return new

    def add_document(self,identity,project,title,records):
        if not records:raise ValueError('Documento vacío.')
        keys={r['key'] for r in records}
        if len(keys)!=len(records) or any(not k.startswith('section:') for k in keys):raise ValueError('Identidades incorrectas.')
        seen=set()
        for i,r in enumerate(records):
            if (i==0 and r.get('parent') is not None) or (i>0 and r.get('parent') not in seen):raise ValueError('Árbol incorrecto.')
            seen.add(r['key'])
        with self.db() as db:
            if db.execute('SELECT 1 FROM works WHERE id=?',(identity,)).fetchone():raise ValueError('El documento ya existe; no se sobrescribe.')
            db.execute('INSERT INTO works(id,project,root,title,storage) VALUES(?,?,?,?,?)',
                (identity,project,records[0]['key'],title,'local'))
            for i,r in enumerate(records):
                db.execute('INSERT INTO document_nodes VALUES(?,?,?,?,?,?,?)',
                    (identity,r['key'],r.get('parent'),i,r['fields']['subject'],r['fields']['description'],1))
        return self.work(identity)

    def document_snapshot(self,work):
        with self.db() as db:
            rows=db.execute('SELECT * FROM document_nodes WHERE work=? ORDER BY position,key',(work['id'],)).fetchall()
        return dict(format=1,service='cosmoSys',storage='academic-local',document_id=work['id'],
            project={'identifier':work['project'],'name':work['title']},records=[dict(
                key=r['key'],parent=r['parent'],revision=r['revision'],label='Sección del documento',
                editable=['subject','description'],fields={'subject':r['subject'],'description':r['description']}) for r in rows])

    def document_changes(self,work,changes,dry_run=False):
        import hashlib
        changed=[]
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            for change in changes:
                after=change['after']
                if not after or not set(after)<={'subject','description'} or any(not isinstance(v,str) for v in after.values()):raise ValueError('Campos inválidos.')
                if change.get('create'):
                    parent=change['create']['parent'];source=change['create']['source']
                    if not all(db.execute('SELECT 1 FROM document_nodes WHERE work=? AND key=?',(work,k)).fetchone() for k in (parent,source)):raise ValueError('Alta fuera del documento.')
                    key='section:'+hashlib.sha256((work+change['key']).encode()).hexdigest()
                    old=db.execute('SELECT * FROM document_nodes WHERE work=? AND key=?',(work,key)).fetchone()
                    if old:
                        if old['subject']!=after.get('subject','') or old['description']!=after.get('description',''):raise ValueError('Alta ya existente con otro contenido.')
                        continue
                    position=db.execute('SELECT coalesce(max(position),0)+1 FROM document_nodes WHERE work=?',(work,)).fetchone()[0]
                    if not dry_run:db.execute('INSERT INTO document_nodes VALUES(?,?,?,?,?,?,?)',(work,key,parent,position,after.get('subject',''),after.get('description',''),1))
                else:
                    key=change['key'];old=db.execute('SELECT * FROM document_nodes WHERE work=? AND key=?',(work,key)).fetchone()
                    if not old:raise ValueError('Sección desconocida.')
                    if all(old[k]==v for k,v in after.items()):continue
                    if old['revision']!=change['revision'] or set(change['before'])!=set(after) or any(old[k]!=v for k,v in change['before'].items()):raise ValueError('El texto cambió; vuelve a cargarlo.')
                    if not dry_run:db.execute('UPDATE document_nodes SET subject=?,description=?,revision=revision+1 WHERE work=? AND key=?',(after.get('subject',old['subject']),after.get('description',old['description']),work,key))
                changed.append(key)
        return {'changed':changed}
