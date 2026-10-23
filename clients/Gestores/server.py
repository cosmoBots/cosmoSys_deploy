from application import *
from academic_format import apply_base_format

def handler(application):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def send(self,status,body,ctype='application/json; charset=utf-8',extra=None):
            if not isinstance(body,bytes):body=json.dumps(body,ensure_ascii=False).encode()
            self.send_response(status);self.send_header('Content-Type',ctype)
            self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store')
            self.send_header('X-Content-Type-Options','nosniff')
            self.send_header('Referrer-Policy','no-referrer')
            self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'")
            for k,v in (extra or {}).items():self.send_header(k,v)
            self.end_headers();self.wfile.write(body)
        def session(self):
            if self.headers.get('Host') not in {f'127.0.0.1:{application.port}',f'localhost:{application.port}'}:return None
            cookie=http.cookies.SimpleCookie()
            try:cookie.load(self.headers.get('Cookie',''))
            except http.cookies.CookieError:return None
            key=cookie.get('gestor_'+application.mode)
            session=application.sessions.get(key.value) if key else None
            return session if session and time.time()-session[1]<43200 else None
        def do_GET(self):
            q=urllib.parse.urlsplit(self.path);args=urllib.parse.parse_qs(q.query)
            if q.path=='/abrir' and self.headers.get('Host') in {f'localhost:{application.port}',f'127.0.0.1:{application.port}'}:
                if not hmac.compare_digest(args.get('clave',[''])[0],application.key):self.send(403,{'error':'Acceso incorrecto.'});return
                sid=secrets.token_urlsafe(32);application.sessions[sid]=(secrets.token_urlsafe(32),time.time())
                self.send(303,b'',extra={'Location':'/','Set-Cookie':f'gestor_{application.mode}={sid}; Path=/; HttpOnly; SameSite=Strict'});return
            session=self.session()
            if not session:
                if q.path in ('/','/login.js','/style.css') and self.headers.get('Host') in {f'localhost:{application.port}',f'127.0.0.1:{application.port}'}:
                    name={'/':'login.html','/login.js':'login.js','/style.css':'style.css'}[q.path]
                    ctype={'/':'text/html; charset=utf-8','/login.js':'text/javascript; charset=utf-8','/style.css':'text/css; charset=utf-8'}[q.path]
                    self.send(200,(ROOT/'static'/name).read_bytes(),ctype);return
                self.send(401,b'Abre el acceso directo del gestor en Windows para iniciar una sesion local.','text/plain; charset=utf-8');return
            if q.path=='/api/session':self.send(200,{'csrf':session[0]});return
            if q.path in ['/','/app.js','/style.css']:
                name={'/':'index.html','/app.js':'app.js','/style.css':'style.css'}[q.path]
                ctype={'/':'text/html; charset=utf-8','/app.js':'text/javascript; charset=utf-8','/style.css':'text/css; charset=utf-8'}[q.path]
                self.send(200,(ROOT/'static'/name).read_bytes(),ctype);return
            if q.path=='/export':
                try:
                    with application.lock:
                        w,s,b=application.snapshot(args['work'][0])
                        if args.get('node'):b=bridge.branch(s,args['node'][0]) if args['node'][0] in {r['key'] for r in b['records']} else None
                        if not b:raise ValueError('Rama no válida.')
                        with tempfile.TemporaryDirectory() as td:
                            f=Path(td)/'documento.docx';bridge.write_docx(b,f)
                            profile=args.get('profile',['standard'])[0]
                            if profile not in ('standard','academic-base'):raise ValueError('Perfil desconocido.')
                            if profile=='academic-base':
                                if application.mode!='academico':raise ValueError('Perfil exclusivo del gestor académico.')
                                apply_base_format(f)
                            raw=f.read_bytes()
                    self.send(200,raw,'application/vnd.openxmlformats-officedocument.wordprocessingml.document',{'Content-Disposition':'attachment; filename="documento.docx"'})
                except Exception as e:self.send(400,{'error':str(e)})
                return
            self.send(404,{'error':'Página no encontrada.'})
        def do_POST(self):
            if self.path=='/login':
                origin=self.headers.get('Origin')
                if self.headers.get('Host') not in {f'localhost:{application.port}',f'127.0.0.1:{application.port}'} or origin not in {f'http://localhost:{application.port}',f'http://127.0.0.1:{application.port}'} or self.headers.get('X-Login-Request')!='1':
                    self.send(403,{'error':'Origen no válido.'});return
                try:
                    length=int(self.headers.get('Content-Length','0'))
                    if not 0<length<10000:raise ValueError('Petición no válida.')
                    data=json.loads(self.rfile.read(length));client.authenticate(data['login'],data['password'])
                    sid=secrets.token_urlsafe(32);application.sessions[sid]=(secrets.token_urlsafe(32),time.time())
                    self.send(200,{'ok':True},extra={'Set-Cookie':f'gestor_{application.mode}={sid}; Path=/; HttpOnly; SameSite=Strict'})
                except Exception as e:self.send(401,{'error':str(e)})
                return
            session=self.session()
            if not session or not hmac.compare_digest(self.headers.get('X-CSRF-Token',''),session[0]):self.send(403,{'error':'Sesión no válida.'});return
            try:
                length=int(self.headers.get('Content-Length','0'))
                if length<1 or length>22_000_000:raise ValueError('Petición demasiado grande.')
                p=json.loads(self.rfile.read(length))
                with application.lock:result=application.api(self.path,p)
                self.send(200,result)
            except Exception as e:self.send(400,{'error':str(e)})
    return Handler

def main():
    parser=argparse.ArgumentParser();parser.add_argument('mode',choices=MODES);parser.add_argument('--serve',action='store_true');args=parser.parse_args()
    app=Application(args.mode)
    if not args.serve:
        import urllib.request
        try:urllib.request.urlopen(f'http://127.0.0.1:{app.port}/',timeout=2)
        except urllib.error.HTTPError:pass
        except OSError:
            subprocess.Popen([sys.executable,str(Path(__file__)),args.mode,'--serve'],creationflags=subprocess.CREATE_NO_WINDOW,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            for _ in range(50):
                time.sleep(.2)
                try:urllib.request.urlopen(f'http://127.0.0.1:{app.port}/',timeout=1);break
                except urllib.error.HTTPError:break
                except OSError:continue
        webbrowser.open(f'http://127.0.0.1:{app.port}/abrir?clave={app.key}')
        return
    ThreadingHTTPServer(('127.0.0.1',app.port),handler(app)).serve_forever()

if __name__=='__main__':main()
