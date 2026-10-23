import sqlite3,json
from contextlib import contextmanager

class Store:
    def __init__(self,path):
        self.path=path
        with self.db() as db:
            db.executescript('''CREATE TABLE IF NOT EXISTS works(id TEXT PRIMARY KEY, project TEXT NOT NULL, root TEXT NOT NULL, title TEXT NOT NULL, UNIQUE(project,root));
            CREATE TABLE IF NOT EXISTS notes(work TEXT NOT NULL,node TEXT NOT NULL,data TEXT NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(work,node));''')
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
            db.execute('INSERT INTO works VALUES(?,?,?,?)',(token,project,root,title))
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
