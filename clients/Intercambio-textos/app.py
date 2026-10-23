import copy
import difflib
import threading
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from tkinter.scrolledtext import ScrolledText
from pathlib import Path
import json
import base64
import urllib.request
import bridge
import webbrowser

import rest_adapter
bridge.server = rest_adapter.server
projects = rest_adapter.projects


def main():
    app = tk.Tk()
    app.title("Textos de cosmoSys y CGRol — Word y texto reversible")
    app.geometry("1050x790")
    status = tk.StringVar(value="Selecciona el servicio y carga sus proyectos. No interviene ningún modelo de IA.")
    ttk.Label(app, textvariable=status, wraplength=1000).pack(fill="x", padx=12, pady=10)
    bar = ttk.Frame(app); bar.pack(fill="x", padx=12)
    service = tk.StringVar(value="cosmoSys")
    services = ttk.Combobox(bar, textvariable=service, values=list(bridge.SERVICES), state="readonly", width=12)
    services.pack(side="left", padx=4)
    choice = ttk.Combobox(bar, state="readonly", width=54); choice.pack(side="left", padx=4)
    current = {"projects": {}, "snapshot": None}
    controls = []
    listbox = ttk.Treeview(app, selectmode="extended", show="tree")
    ttk.Label(app, text="Selecciona la raíz de tu documento y pulsa Exportar rama. Se incluirán sus descendientes en el orden del árbol.").pack(anchor="w", padx=12, pady=(12, 4))
    listbox.pack(fill="both", expand=True, padx=12)
    actions = ttk.Frame(app); actions.pack(fill="x", padx=12, pady=10)
    ttk.Label(app, text="Diferencias antes de importar").pack(anchor="w", padx=12)
    diff = ScrolledText(app, height=14, wrap="word", state="disabled")
    diff.pack(fill="both", expand=True, padx=12, pady=6)
    bottom = ttk.Frame(app); bottom.pack(fill="x", padx=12, pady=8)

    def show(text):
        diff.configure(state="normal"); diff.delete("1.0", "end"); diff.insert("1.0", text); diff.configure(state="disabled")

    def busy(job, done, message):
        status.set(message)
        for button in controls:
            button.configure(state="disabled")
        services.configure(state="disabled"); choice.configure(state="disabled")
        def finish(result=None, error=None):
            for button in controls:
                button.configure(state="normal")
            services.configure(state="readonly"); choice.configure(state="readonly")
            if error:
                status.set("Operación detenida. No se ha confirmado el guardado.")
                messagebox.showerror("Intercambio de textos", error)
            else:
                try:
                    done(result)
                except Exception as exc:
                    messagebox.showerror("Intercambio de textos", str(exc))
        def run():
            try:
                result = job()
                app.after(0, lambda: finish(result=result))
            except Exception as exc:
                error = str(exc)
                app.after(0, lambda: finish(error=error))
        threading.Thread(target=run, daemon=True).start()

    def clear(event=None):
        current["snapshot"] = None; current["projects"] = {}
        listbox.delete(*listbox.get_children()); choice.set(""); choice["values"] = []
    services.bind("<<ComboboxSelected>>", clear)
    choice.bind("<<ComboboxSelected>>", lambda event: current.update(snapshot=None))

    def load_projects():
        target = service.get()
        def done(items):
            clear()
            current["projects"] = {f'{p["name"]} ({p["identifier"]})': p["identifier"] for p in items}
            choice["values"] = list(current["projects"])
            status.set("Elige un proyecto y pulsa «Leer textos».")
        busy(lambda: projects(target), done, "Leyendo los proyectos accesibles…")

    def load():
        identifier = current["projects"].get(choice.get())
        if not identifier:
            messagebox.showinfo("Proyecto", "Carga y selecciona primero un proyecto."); return
        target = service.get()
        def done(data):
            current["snapshot"] = data; listbox.delete(*listbox.get_children())
            listbox.insert('', 'end', iid='issues', text='Árbol de fichas — fuentes, universo y obras', open=True)
            listbox.insert('', 'end', iid='wiki', text='Páginas de trabajo y transcripciones', open=False)
            pending = list(data['records'])
            keys = {r['key'] for r in pending}
            while pending:
                ready = [r for r in pending if r.get('parent') not in keys or listbox.exists(r['parent'])]
                if not ready:
                    raise ValueError('El árbol contiene una relación circular.')
                for record in ready:
                    preview = record['fields'].get('subject', '').replace('\n', ' ')
                    parent = record.get('parent')
                    if parent not in keys:
                        parent = 'issues' if record['key'].startswith('issue:') else 'wiki'
                    listbox.insert(parent, 'end', iid=record['key'], text=preview or record['label'], open=False)
                    pending.remove(record)
            status.set(f'{len(data["records"])} fichas y páginas. Despliega las ramas para elegir el documento.')
        busy(lambda: bridge.snapshot(target, identifier), done, "Leyendo textos y sus versiones…")

    def export(as_branch=True):
        data = current["snapshot"]
        selected = listbox.selection()
        if not data or not selected:
            messagebox.showinfo("Selección", "Lee el proyecto y selecciona al menos una ficha o página."); return
        try:
            if as_branch:
                if len(selected) != 1:
                    raise ValueError('Selecciona una sola raíz; sus descendientes se incluirán automáticamente.')
                subset = bridge.branch(data, selected[0])
            else:
                subset = copy.deepcopy(data)
                subset['records'] = [r for r in subset['records'] if r['key'] in selected]
                if not subset['records']:
                    raise ValueError('Selecciona fichas o páginas, no los grupos de navegación.')
        except ValueError as exc:
            messagebox.showinfo('Seleccionar documento', str(exc)); return
        filename = filedialog.asksaveasfilename(defaultextension=".docx", initialfile=data["project"]["identifier"] + ".docx",
                      filetypes=[("Word Open XML", "*.docx"), ("Texto con marcas de identidad", "*.txt")])
        if not filename:
            return
        def job():
            if Path(filename).suffix.lower() == ".docx":
                bridge.write_docx(subset, filename)
            elif Path(filename).suffix.lower() == ".txt":
                bridge.write_txt(subset, filename)
            else:
                raise ValueError("Usa la extensión .docx o .txt.")
            check, values = bridge.read_document(filename)
            if bridge.plan(check, values):
                raise RuntimeError("El documento no superó la comprobación de exportación.")
            return filename
        busy(job, lambda value: status.set("Exportado y comprobado: " + value), "Preparando el documento…")

    def import_file():
        filename = filedialog.askopenfilename(filetypes=[("Word o texto", "*.docx *.txt")])
        if not filename:
            return
        def inspect():
            manifest, values = bridge.read_document(filename)
            changes = bridge.plan(manifest, values)
            if changes:
                bridge.server(manifest["service"], manifest["project"]["identifier"], "check", changes)
            return manifest, changes
        def inspected(result):
            manifest, changes = result
            if not changes:
                show("El documento no contiene cambios de texto."); status.set("No hay nada que importar."); return
            target = f'{manifest["service"]} · {manifest["project"]["name"]}'
            lines = ["Destino: " + target, ""]
            for change in changes:
                if change.get('create'):
                    parent = change['create']['parent']
                    parent_record = next(r for r in manifest['records'] if r['key'] == parent)
                    lines.extend(['APARTADO NUEVO: ' + change['after']['subject'],
                                  'Dentro de: ' + parent_record['fields']['subject'], ''])
                for field in change["after"]:
                    lines.extend(difflib.unified_diff(change["before"].get(field, '').splitlines(),
                        change["after"][field].splitlines(), fromfile=change["key"] + " original",
                        tofile=change["key"] + " corregido", lineterm=""))
            show("\n".join(lines))
            status.set("Revisa las diferencias. El servidor volverá a comprobarlas al guardar.")
            review = tk.Toplevel(app); review.title("Revisar antes de guardar"); review.geometry("850x600")
            ttk.Label(review, text=f"Destino: {target}\n{len(changes)} fichas o páginas con cambios.").pack(pady=8)
            review_text = ScrolledText(review, wrap="word")
            review_text.pack(fill="both", expand=True, padx=12)
            review_text.insert("1.0", "\n".join(lines)); review_text.configure(state="disabled")
            def commit():
                review.destroy()
                # Re-read and require exactly the version the user reviewed.
                def save():
                    newer, newvalues = bridge.read_document(filename)
                    if newer != manifest or bridge.plan(newer, newvalues) != changes:
                        raise ValueError("El archivo cambió después de revisarlo. Ábrelo de nuevo.")
                    return bridge.apply_document(filename, commit=True)
                def saved(result):
                    current["snapshot"] = None
                    status.set(f'Guardado atómico confirmado: {len(result["changed"])} fichas/páginas. Vuelve a leer el proyecto antes de exportar.')
                    messagebox.showinfo("Importación terminada", "Cambios guardados. Vuelve a leer los textos del proyecto para exportar su nueva versión.")
                busy(save, saved, "Guardando todos los cambios en una transacción…")
            ttk.Button(review, text="Aplicar estos cambios", command=commit).pack(side="right", padx=12, pady=10)
            ttk.Button(review, text="Cancelar", command=review.destroy).pack(side="right", pady=10)
        busy(inspect, inspected, "Comprobando identidades, permisos y posibles conflictos…")

    def open_tree():
        identifier = current['projects'].get(choice.get())
        if identifier:
            port = 3080 if service.get() == 'cosmoSys' else 3090
            webbrowser.open(rest_adapter.base_url(service.get()) + f'/{identifier}/cosmosys/tree')

    for frame, label, callback in [(bar, "Cargar proyectos", load_projects), (bar, "Leer árbol", load),
            (actions, "Abrir árbol en cosmoSys", open_tree),
            (actions, "Exportar rama…", export), (actions, "Exportar fichas sueltas…", lambda: export(False)),
            (bottom, "Abrir documento corregido…", import_file)]:
        button = ttk.Button(frame, text=label, command=callback); button.pack(side="left", padx=4)
        controls.append(button)
    ttk.Label(app, text="Puedes copiar un apartado con su título y texto al final de la rama en Word. Revisa las altas antes de guardar. Para reordenar, usa cosmoSys.", wraplength=1000).pack(pady=6)
    app.mainloop()


if __name__ == "__main__":
    main()
