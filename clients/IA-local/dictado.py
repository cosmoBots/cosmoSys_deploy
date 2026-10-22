"""Dictado local con proyecto fijado antes de grabar y revisión antes de publicar."""
import hashlib
import html
import json
import queue
import threading
import time
import uuid
import wave
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote
import actas

ROOT = Path(__file__).resolve().parent


class Recorder:
    def __init__(self):
        self.stream = None
        self.blocks = []
        self.frames = 0
        self.warning = False
        self.rate = 48000
        self.limit = False

    def start(self, device):
        import sounddevice as sd
        self.rate = int(sd.query_devices(device)['default_samplerate'])
        self.blocks, self.frames, self.warning, self.limit = [], 0, False, False
        def receive(data, frames, timing, status):
            self.warning = self.warning or bool(status)
            remaining = self.rate * 600 - self.frames
            if remaining <= 0:
                self.limit = True
                raise sd.CallbackStop
            count = min(frames, remaining)
            self.blocks.append(bytes(data)[:count * 2])
            self.frames += count
            if count < frames:
                self.limit = True
                raise sd.CallbackStop
        self.stream = sd.RawInputStream(device=device, samplerate=self.rate,
            channels=1, dtype='int16', callback=receive)
        try:
            self.stream.start()
        except Exception:
            self.stream.close(); self.stream = None
            raise

    def stop(self, path):
        if self.stream:
            try:
                if getattr(self.stream, 'active', True):
                    self.stream.stop()
            finally:
                self.stream.close(); self.stream = None
        if not self.frames:
            raise ValueError('No se recibió audio del micrófono.')
        with wave.open(str(path), 'wb') as output:
            output.setnchannels(1); output.setsampwidth(2); output.setframerate(self.rate)
            for block in self.blocks:
                output.writeframesraw(block)
        self.blocks.clear()
        return str(path)


def build_content(title, text, original, mode):
    if not title.strip() or not text.strip():
        raise ValueError('Escribe un título y revisa el texto antes de guardar.')
    # Plain text is escaped so dictation cannot turn into Redmine macros.
    content = 'h1. Dictado revisado\n\n<pre>\n' + html.escape(title.strip()) + '\n</pre>\n\n'
    content += 'Origen: dictado local revisado por el usuario. Tipo: ' + mode + '.\n\n'
    content += '<pre>\n' + html.escape(text.strip()) + '\n</pre>'
    if original.strip() != text.strip():
        content += '\n\nh2. Transcripción de origen\n\n<pre>\n' + html.escape(original.strip()) + '\n</pre>'
    return content


def publish(service, identifier, content, session):
    # Stable page per payload: retry after an uncertain response cannot duplicate it.
    digest = hashlib.sha256((service + '\0' + identifier + '\0' + content).encode()).hexdigest()[:16]
    page = 'Dictado_' + session + '_' + digest
    path = '/projects/' + quote(identifier, safe='') + '/wiki/' + page
    try:
        existing = actas.project_api(service, path + '.json')['wiki_page']['text']
    except HTTPError as error:
        if error.code != 404:
            raise
        existing = None
    if existing is not None and existing != content:
        raise ValueError('La página ya existe con otro contenido. No se ha sobrescrito.')
    if existing is None:
        actas.project_api(service, path + '.json', {'wiki_page': {'text': content,
            'comments': 'Dictado local revisado antes de guardar'}})
    if actas.project_api(service, path + '.json')['wiki_page']['text'] != content:
        raise RuntimeError('No se pudo verificar el guardado. Conserva la copia local y reintenta sin cambiar el texto.')
    return actas.service_url(service) + path


def main():
    import tkinter as tk
    from tkinter import ttk, messagebox, filedialog
    from tkinter.scrolledtext import ScrolledText
    import sounddevice as sd
    app = tk.Tk(); app.title('Dictado integrado — cosmoSys y CGRol'); app.geometry('1050x780')
    recorder = Recorder(); events = queue.Queue()
    state = {'busy': False, 'recording': False, 'projects': {}, 'target': None,
             'original': '', 'session': uuid.uuid4().hex, 'started': 0}
    status = tk.StringVar(value='Elige destino y proyecto antes de hablar. El micrófono está apagado.')
    ttk.Label(app, textvariable=status, wraplength=1000).pack(fill='x', padx=12, pady=10)
    top = ttk.Frame(app); top.pack(fill='x', padx=12)
    service = tk.StringVar(value='cosmoSys')
    dest = ttk.Combobox(top, values=['cosmoSys', 'CGRol'], textvariable=service, width=12, state='readonly'); dest.pack(side='left', padx=4)
    project = ttk.Combobox(top, width=57, state='readonly'); project.pack(side='left', padx=4)
    microw = ttk.Frame(app); microw.pack(fill='x', padx=12, pady=10)
    devices = {f'{d["name"]} · entrada {i}': i for i, d in enumerate(sd.query_devices()) if d['max_input_channels'] > 0}
    mic = ttk.Combobox(microw, values=list(devices), width=60, state='readonly'); mic.pack(side='left', padx=4)
    preferred = next((name for name in devices if 'micr' in name.lower()), next(iter(devices), ''))
    mic.set(preferred)
    title = tk.StringVar()
    titlebar = ttk.Frame(app); titlebar.pack(fill='x', padx=12, pady=6)
    ttk.Label(titlebar, text='Título de la nota').pack(side='left')
    title_entry = ttk.Entry(titlebar, textvariable=title); title_entry.pack(side='left', fill='x', expand=True, padx=8)
    mode = tk.StringVar(value='Nota de universo')
    modebox = ttk.Combobox(titlebar, values=['Nota de universo', 'Nota de partida', 'Nota de desarrollo', 'Acta'], textvariable=mode, state='readonly', width=22)
    modebox.pack(side='left')
    ttk.Label(app, text='Texto editable · cada grabación se añade al final').pack(anchor='w', padx=12, pady=(8, 0))
    editor = ScrolledText(app, height=23, wrap='word'); editor.pack(fill='both', expand=True, padx=12, pady=6)
    actions = ttk.Frame(app); actions.pack(fill='x', padx=12, pady=10)
    buttons = []

    def refresh():
        locked = state['busy'] or state['recording']
        for button in buttons:
            button.configure(state='disabled' if locked else 'normal')
        record_button.configure(state='disabled' if state['busy'] else 'normal', text='Detener y transcribir' if state['recording'] else 'Hablar')
        for widget in (dest, project, mic, modebox):
            widget.configure(state='disabled' if locked or (state['target'] and widget in (dest, project)) else 'readonly')
        editor.configure(state='disabled' if locked else 'normal')
        title_entry.configure(state='disabled' if locked else 'normal')

    def busy(job, done, label):
        state['busy'] = True; status.set(label); refresh()
        def worker():
            try:
                events.put((done, job(), None))
            except Exception as error:
                events.put((done, None, str(error)))
        threading.Thread(target=worker, daemon=True).start()

    def poll():
        try:
            done, value, error = events.get_nowait()
        except queue.Empty:
            pass
        else:
            state['busy'] = False; refresh()
            if error:
                status.set('Operación detenida. El texto y la grabación local se conservan.')
                messagebox.showerror('Dictado local', error)
            else:
                done(value)
        if state['recording']:
            elapsed = int(time.monotonic() - state['started'])
            status.set(f'GRABANDO · {elapsed // 60:02}:{elapsed % 60:02} · {state["target"][2]} · límite 10 minutos')
            if recorder.stream and not recorder.stream.active:
                recorder.warning = not recorder.limit
                toggle_record()
            elif recorder.limit or elapsed >= 600:
                toggle_record()
        app.after(150, poll)

    def clear_projects(event=None):
        state['projects'] = {}; project.set(''); project['values'] = []
    dest.bind('<<ComboboxSelected>>', clear_projects)

    def load_projects():
        chosen = service.get()
        def loaded(items):
            state['projects'] = {f'{p["name"]} ({p["identifier"]})': p['identifier'] for p in items}
            project['values'] = list(state['projects']); project.set('')
            status.set('Selecciona un proyecto. Después pulsa Hablar.')
        busy(lambda: actas.projects(chosen), loaded, 'Consultando proyectos…')

    def target():
        if state['target']:
            return state['target']
        identifier = state['projects'].get(project.get())
        if not identifier:
            raise ValueError('Carga los proyectos y selecciona uno antes de dictar.')
        state['target'] = (service.get(), identifier, project.get()); refresh()
        return state['target']

    def add_segments(segments):
        text = ' '.join(s['text'] for s in segments).strip()
        if not text:
            status.set('No se ha reconocido voz. Comprueba el micrófono; el audio se conserva localmente.'); return
        if editor.get('1.0', 'end').strip():
            editor.insert('end', '\n\n')
        editor.insert('end', text)
        state['original'] += ('\n\n' if state['original'] else '') + text
        status.set('Transcripción lista. Corrige el texto, escribe el título y guarda cuando quieras.')

    def toggle_record():
        if state['recording']:
            state['recording'] = False
            folder = ROOT / 'dictados'; folder.mkdir(exist_ok=True)
            path = folder / (time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8] + '.wav')
            try:
                recorder.stop(path)
            except Exception as error:
                refresh(); messagebox.showerror('Micrófono', str(error)); return
            if recorder.warning:
                messagebox.showwarning('Audio', 'Se detectaron cortes en la captura. Revisa la transcripción.')
            busy(lambda: actas.transcribe(str(path)), add_segments, 'Micrófono apagado. Transcribiendo en tu ordenador…')
        else:
            try:
                target()
                if mic.get() not in devices:
                    raise ValueError('No hay un micrófono seleccionado.')
                recorder.start(devices[mic.get()])
                state['recording'] = True; state['started'] = time.monotonic(); refresh()
            except Exception as error:
                messagebox.showerror('Micrófono', str(error) + '\nSi Windows lo bloquea, revisa Privacidad y seguridad → Micrófono.')

    def import_audio():
        try:
            target()
        except ValueError as error:
            messagebox.showinfo('Proyecto', str(error)); return
        filename = filedialog.askopenfilename(filetypes=[('Audio', '*.wav *.mp3 *.m4a *.ogg *.flac *.mp4'), ('Todos', '*.*')])
        if filename:
            busy(lambda: actas.transcribe(filename), add_segments, 'Transcribiendo el archivo local…')

    def generate_minutes():
        text = editor.get('1.0', 'end').strip()
        if not text:
            return
        state['original'] = text
        def done(value):
            editor.delete('1.0', 'end'); editor.insert('1.0', value); mode.set('Acta')
            status.set('Borrador de acta listo. Revisa antes de guardar.')
        busy(lambda: actas.minutes(text), done, 'Preparando acta con IA local…')

    def save_local():
        filename = filedialog.asksaveasfilename(defaultextension='.txt', initialfile='Dictado.txt')
        if filename:
            Path(filename).write_text(title.get() + '\n\n' + editor.get('1.0', 'end'), encoding='utf-8')
            status.set('Copia local guardada.')

    def save_project():
        try:
            destination, identifier, label = target()
            text = editor.get('1.0', 'end').strip()
            content = build_content(title.get(), text, state['original'], mode.get())
        except ValueError as error:
            messagebox.showinfo('Revisar', str(error)); return
        if not messagebox.askyesno('Guardar dictado revisado', f'Destino: {destination}\nProyecto: {label}\nTítulo: {title.get()}\n\nSe creará una página wiki con el texto revisado. ¿Guardar?'):
            return
        folder = ROOT / 'dictados'; folder.mkdir(exist_ok=True)
        (folder / (state['session'] + '-texto.json')).write_text(json.dumps({'service': destination, 'project': identifier, 'content': content}, ensure_ascii=False), encoding='utf-8')
        def saved(url):
            status.set('Guardado y verificado: ' + url)
            messagebox.showinfo('Dictado guardado', url)
        busy(lambda: publish(destination, identifier, content, state['session']), saved, 'Guardando en el proyecto seleccionado…')

    def new_note():
        if editor.get('1.0', 'end').strip() and not messagebox.askyesno('Nueva nota', '¿Vaciar el editor y empezar otra nota? Guarda antes una copia si la necesitas.'):
            return
        editor.delete('1.0', 'end'); title.set('')
        state.update(target=None, original='', session=uuid.uuid4().hex)
        refresh(); status.set('Nueva nota. Elige destino y proyecto.')

    for frame, label, command in [(top, 'Cargar proyectos', load_projects), (actions, 'Añadir audio…', import_audio),
            (actions, 'Preparar acta', generate_minutes), (actions, 'Guardar copia…', save_local),
            (actions, 'Guardar en proyecto…', save_project), (actions, 'Nueva nota', new_note)]:
        button = ttk.Button(frame, text=label, command=command); button.pack(side='left', padx=4); buttons.append(button)
    record_button = ttk.Button(microw, text='Hablar', command=toggle_record); record_button.pack(side='left', padx=8)
    ttk.Label(app, text='Audio y texto se conservan en IA-local/dictados. Sólo se envía el texto revisado al proyecto al guardar.').pack(pady=6)
    def close():
        if state['busy']:
            messagebox.showinfo('Operación en curso', 'Espera a que termine para cerrar sin perder el resultado.'); return
        if state['recording']:
            toggle_record(); return
        if editor.get('1.0', 'end').strip() and not messagebox.askyesno('Cerrar', '¿Cerrar el editor? Comprueba que has guardado el texto que quieras conservar.'):
            return
        app.destroy()
    app.protocol('WM_DELETE_WINDOW', close)
    refresh(); poll(); app.mainloop()


if __name__ == '__main__':
    main()
