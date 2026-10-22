"""Two independent localhost applications, with references to cosmoSys records."""
import argparse, base64, hashlib, hmac, http.cookies, io, json, os, secrets
import sqlite3, subprocess, sys, tempfile, threading, time, urllib.parse, webbrowser
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

ROOT=Path(__file__).resolve().parent
EXCHANGE=ROOT.parent/'Intercambio-textos'
sys.path.insert(0,str(EXCHANGE))
import bridge
import cosmosys_client as client
from cosmosys_client import projects, create_node
MODES={'historias':('Gestor de historias',3110),'academico':('Gestor académico',3120)}

from store import Store

class Application:
    def __init__(self,mode):
        self.mode=mode;self.title,self.port=MODES[mode]
        self.data=ROOT/'datos'/mode;self.data.mkdir(parents=True,exist_ok=True)
        self.store=Store(self.data/'gestor.sqlite3')
        key=self.data/'acceso-local.key'
        if not key.exists():key.write_text(secrets.token_urlsafe(40),encoding='ascii')
        self.key=key.read_text(encoding='ascii').strip()
        self.sessions={};self.pending={};self.lock=threading.RLock()
    def snapshot(self,work):
        w=self.store.work(work);s=client.snapshot(w['project']);b=bridge.branch(s,w['root'])
        return w,s,b
    def api(self,path,p):
        if path=='/api/init':return dict(title=self.title,mode=self.mode,works=self.store.works(),projects=projects('cosmoSys'))
        if path=='/api/project':return client.snapshot(p['project'])
        if path=='/api/connect':
            if not p.get('root'):p['root']=create_node(p['project'],p['title'],None,p['token'],template=p.get('template',''))['key']
            s=client.snapshot(p['project']);b=bridge.branch(s,p['root'])
            return self.store.add(p['token'],p['project'],p['root'],b['records'][0]['fields']['subject'])
        if path=='/api/work':
            w,s,b=self.snapshot(p['work']);return dict(work=w,branch=b,notes=self.store.notes(w['id']),sources=[r for r in s['records'] if r['key'].startswith('issue:')])
        if path=='/api/node':
            w,s,b=self.snapshot(p['work']);keys={r['key'] for r in b['records']}
            if p['parent'] not in keys:raise ValueError('El padre no pertenece al trabajo.')
            return create_node(w['project'],p['title'],p['parent'],p['token'])
        if path=='/api/save-text':
            w,s,b=self.snapshot(p['work']);r=next((r for r in b['records'] if r['key']==p['node']),None)
            if not r:raise ValueError('Apartado fuera del trabajo.')
            before=p['before'];after=p['after']
            if set(before)!=set(after) or not set(after)<=set(r['editable']):raise ValueError('Campos no editables.')
            return client.server('cosmoSys',w['project'],'apply',[dict(key=r['key'],revision=p['revision'],before=before,after=after)])
        if path=='/api/save-notes':
            w,s,b=self.snapshot(p['work'])
            if p['node'] not in {r['key'] for r in b['records']}:raise ValueError('Apartado fuera del trabajo.')
            data=p['data'];allowed={'type','viewpoint','chronology','objective','status','evidence','authors','year','publication','doi','reference','citation','sources'}
            if not isinstance(data,dict) or set(data)-allowed:raise ValueError('Notas incorrectas.')
            if any(not isinstance(v,str) or len(v)>50000 for k,v in data.items() if k!='sources'):raise ValueError('Notas demasiado extensas.')
            refs=data.get('sources',[])
            if not isinstance(refs,list) or len(refs)>100 or not set(refs)<={r['key'] for r in s['records']}:raise ValueError('Referencia no accesible.')
            return dict(revision=self.store.save_notes(w['id'],p['node'],data,int(p['revision'])))
        if path=='/api/import-preview':
            w,s,b=self.snapshot(p['work'])
            raw=base64.b64decode(p['file'],validate=True)
            if len(raw)>15_000_000:raise ValueError('El Word supera los 15 MB.')
            with tempfile.TemporaryDirectory() as td:
                f=Path(td)/'revision.docx';f.write_bytes(raw);m,v=bridge.read_docx(f);changes=bridge.plan(m,v)
            if m.get('service')!='cosmoSys' or m['project']['identifier']!=w['project']:raise ValueError('El Word pertenece a otro proyecto o servicio.')
            keys={r['key'] for r in b['records']}
            for c in changes:
                if c.get('create'):
                    if c['create']['parent'] not in keys or c['create']['source'] not in keys:raise ValueError('Alta fuera del trabajo.')
                elif c['key'] not in keys:raise ValueError('Cambios fuera del trabajo.')
            if changes:client.server('cosmoSys',w['project'],'check',changes)
            token=secrets.token_urlsafe(24);self.pending[token]=(time.time(),w,m,changes)
            return dict(token=token,changes=changes)
        if path=='/api/import-apply':
            item=self.pending.get(p['token'])
            if not item or time.time()-item[0]>1800:raise ValueError('La revisión ha caducado. Carga el Word otra vez.')
            _,w,m,changes=item
            if w['id']!=p['work']:raise ValueError('Trabajo incorrecto.')
            backup=self.data/'recuperacion';backup.mkdir(exist_ok=True)
            (backup/(hashlib.sha256(bridge.canonical(changes)).hexdigest()+'.json')).write_bytes(bridge.canonical(dict(manifest=m,changes=changes)))
            result=client.server('cosmoSys',w['project'],'apply',changes) if changes else dict(changed=[])
            self.pending.pop(p['token'],None);return result
        raise ValueError('Operación no disponible.')
