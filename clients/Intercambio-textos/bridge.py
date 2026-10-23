"""Deterministic editable text exchange. No generated prose or AI dependency."""
import base64
import copy
import hashlib
import hmac
import json
import os
import re
import subprocess
import zipfile
import zlib
from pathlib import Path
from xml.etree import ElementTree as E

ROOT = Path(__file__).resolve().parent
W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
CP = "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties"
VT = "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"
NS = {"w": W, "cp": CP, "vt": VT}
for prefix, uri in NS.items():
    E.register_namespace(prefix, uri)
LABELS = {"subject": "Título", "description": "Descripción", "text": "Texto",
          "cs_reaction": "Reacción conservada", "cs_roll_expression": "Expresión de tirada conservada",
          "cs_roll_result": "Resultado de tirada conservado"}
SERVICES = {"CGRol": "cgrol-redmine-1", "cosmoSys": "cosmosys-redmine-1"}


def canonical(data):
    return json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def signing_key():
    path = ROOT / ".exchange-key"
    if not path.exists():
        try:
            with path.open("xb") as file:
                file.write(os.urandom(32))
        except FileExistsError:
            pass
    return path.read_bytes()


def sign(manifest):
    return {"manifest": manifest, "signature": hmac.new(signing_key(), canonical(manifest), hashlib.sha256).hexdigest()}


def verify(envelope):
    manifest = envelope["manifest"]
    expected = hmac.new(signing_key(), canonical(manifest), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, envelope["signature"]):
        raise ValueError("La identidad del documento está alterada o pertenece a otra instalación.")
    if manifest["format"] != 1 or manifest["service"] not in SERVICES:
        raise ValueError("Formato o destino no admitido.")
    return manifest


def server(*args,**kwargs):
    raise RuntimeError('Use the authenticated HTTP adapter in Gestores.')


def snapshot(service, project):
    data = server(service, project, "export")
    data.update(format=1, service=service)
    # Canonicalize line endings once, without removing spaces or empty lines.
    for record in data["records"]:
        for key, value in record["fields"].items():
            record["fields"][key] = value.replace("\r\n", "\n").replace("\r", "\n")
    return data


def layout(manifest):
    if manifest.get('projection') == 'branch':
        for record in manifest['records']:
            for field in ('subject', 'description'):
                yield 'field', (record['key'] + ':' + field, record['fields'][field])
        return
    yield "heading", f'Textos de {manifest["project"]["name"]}'
    yield "note", "Edición reversible de textos. Edita dentro de los bloques; conserva su identidad."
    for record in manifest["records"]:
        yield "heading", record["label"]
        for field in LABELS:
            if field not in record["fields"]:
                continue
            text = record["fields"][field]
            yield "label", LABELS[field] + ("" if field in record["editable"] else " · solo lectura")
            yield "field", (record["key"] + ":" + field, text)


def plain_text(manifest):
    """Canonical public text projection, also used for round-trip assertions."""
    return "\n".join(value[1] if kind == "field" else value for kind, value in layout(manifest))


def branch(manifest, root_key):
    records = {r['key']: r for r in manifest['records'] if r['key'].startswith('issue:')}
    if root_key not in records:
        raise ValueError('Selecciona una ficha del árbol para exportar su rama.')
    children = {}
    for record in records.values():
        children.setdefault(record.get('parent'), []).append(record)
    selected, visiting = [], set()
    def walk(key, depth):
        if key in visiting:
            raise ValueError('El árbol contiene un ciclo.')
        if depth > 9:
            raise ValueError('La rama supera los nueve niveles de títulos de Word. Selecciona una rama más pequeña.')
        visiting.add(key)
        record = copy.deepcopy(records[key])
        record['depth'] = depth
        record['fields'] = {f: record['fields'][f] for f in ('subject', 'description')}
        record['editable'] = [f for f in record['editable'] if f in record['fields']]
        selected.append(record)
        for child in children.get(key, []):
            walk(child['key'], depth + 1)
    walk(root_key, 0)
    result = copy.deepcopy(manifest)
    result.update(projection='branch', root=root_key, records=selected)
    return result


def field_styles(manifest):
    if manifest.get('projection') != 'branch':
        return {}
    return {r['key'] + ':subject': 'Title' if r['depth'] == 0 else 'Heading' + str(r['depth'])
            for r in manifest['records']}


def wtag(name):
    return "{" + W + "}" + name


def paragraph(text, style=None):
    p = E.Element(wtag("p"))
    if style:
        props = E.SubElement(p, wtag("pPr"))
        E.SubElement(props, wtag("pStyle"), {wtag("val"): style})
    run = E.SubElement(p, wtag("r"))
    for i, chunk in enumerate(text.split("\t")):
        if i:
            E.SubElement(run, wtag("tab"))
        node = E.SubElement(run, wtag("t"), {"{http://www.w3.org/XML/1998/namespace}space": "preserve"})
        node.text = chunk
    return p


def xml(node):
    return E.tostring(node, encoding="utf-8", xml_declaration=True)


def write_docx(manifest, path):
    envelope = sign(manifest)
    heading_styles = field_styles(manifest)
    doc = E.Element(wtag("document"))
    body = E.SubElement(doc, wtag("body"))
    first = True
    for kind, value in layout(manifest):
        if kind == "field":
            key, text = value
            control = E.SubElement(body, wtag("sdt"))
            props = E.SubElement(control, wtag("sdtPr"))
            E.SubElement(props, wtag("tag"), {wtag("val"): key})
            E.SubElement(props, wtag("alias"), {wtag("val"): key})
            E.SubElement(props, wtag("id"), {wtag("val"): str(int(hashlib.sha256(key.encode()).hexdigest()[:7], 16))})
            E.SubElement(props, wtag("lock"), {wtag("val"): "sdtLocked"})
            content = E.SubElement(control, wtag("sdtContent"))
            for line in text.split("\n"):
                content.append(paragraph(line, heading_styles.get(key)))
        else:
            style = "Title" if first else ("Heading1" if kind == "heading" else "Caption" if kind == "label" else "Normal")
            body.append(paragraph(value, style))
            first = False
    sect = E.SubElement(body, wtag("sectPr"))
    E.SubElement(sect, wtag("pgSz"), {wtag("w"): "12240", wtag("h"): "15840"})
    E.SubElement(sect, wtag("pgMar"), {wtag(k): "1080" for k in ["top", "bottom", "left", "right"]})
    custom = E.Element("{" + CP + "}Properties")
    prop = E.SubElement(custom, "{" + CP + "}property",
                        {"fmtid": "{D5CDD505-2E9C-101B-9397-08002B2CF9AE}", "pid": "2", "name": "CosmosysTextExchange"})
    E.SubElement(prop, "{" + VT + "}lpwstr").text = base64.b64encode(zlib.compress(canonical(envelope), 9)).decode()
    styles = f'''<w:styles xmlns:w="{W}">
      <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/><w:color w:val="000000"/></w:rPr></w:rPrDefault>
      <w:pPrDefault><w:pPr><w:spacing w:after="100" w:line="270" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
      <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="Caption"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/></w:pPr><w:rPr><w:b/></w:rPr></w:style>
    </w:styles>'''.encode()
    styles_root = E.fromstring(styles)
    for level in range(2, 10):
        style = E.SubElement(styles_root, wtag('style'), {wtag('type'): 'paragraph', wtag('styleId'): f'Heading{level}'})
        E.SubElement(style, wtag('name'), {wtag('val'): f'heading {level}'})
        E.SubElement(style, wtag('basedOn'), {wtag('val'): 'Normal'})
        props = E.SubElement(style, wtag('pPr'))
        E.SubElement(props, wtag('keepNext'))
        E.SubElement(props, wtag('spacing'), {wtag('before'): '180', wtag('after'): '100'})
        E.SubElement(props, wtag('outlineLvl'), {wtag('val'): str(level-1)})
        run = E.SubElement(style, wtag('rPr'))
        E.SubElement(run, wtag('b'))
        E.SubElement(run, wtag('sz'), {wtag('val'): str(max(22, 28-level*2))})
    styles = xml(styles_root)
    parts = {
        "[Content_Types].xml": b'''<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/docProps/custom.xml" ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/></Types>''',
        "_rels/.rels": b'''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties" Target="docProps/custom.xml"/></Relationships>''',
        "word/_rels/document.xml.rels": b'''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>''',
        "word/document.xml": xml(doc), "word/styles.xml": styles, "docProps/custom.xml": xml(custom)}
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(parts):
            item = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
            item.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(item, parts[name])


def write_txt(manifest, path):
    lines = []
    for kind, value in layout(manifest):
        if kind == "field":
            key, text = value
            if any(line.startswith("[[CS-") for line in text.split("\n")):
                raise ValueError("El texto contiene marcas reservadas para TXT. Usa DOCX.")
            lines.extend([f"[[CS-BEGIN {key}]]", text, f"[[CS-END {key}]]"])
        else:
            lines.append(value)
    Path(path).write_bytes(("\n".join(lines) + "\n").encode("utf-8"))
    Path(str(path) + ".identidad.json").write_bytes(canonical(sign(manifest)))


def safe_xml(raw):
    if b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
        raise ValueError("El documento contiene declaraciones XML no admitidas.")
    return E.fromstring(raw)


def paragraph_text(p):
    chunks = []
    for node in p.iter():
        if node.tag == wtag("t"):
            chunks.append(node.text or "")
        elif node.tag == wtag("tab"):
            chunks.append("\t")
        elif node.tag in (wtag("br"), wtag("cr")):
            if node.get(wtag("type")) not in (None, "textWrapping"):
                raise ValueError("No se admiten saltos de página dentro del texto editable.")
            chunks.append("\n")
    return "".join(chunks)


def read_docx(path):
    with zipfile.ZipFile(path) as archive:
        if len(archive.infolist()) > 1000 or sum(i.file_size for i in archive.infolist()) > 100_000_000:
            raise ValueError("Documento demasiado grande.")
        custom = safe_xml(archive.read("docProps/custom.xml"))
        matches = [n for n in custom if n.get("name") == "CosmosysTextExchange"]
        if len(matches) != 1:
            raise ValueError("Falta la identidad de intercambio. Utiliza el DOCX original.")
        packed = base64.b64decode(matches[0][0].text, validate=True)
        decoder = zlib.decompressobj()
        unpacked = decoder.decompress(packed, 40_000_001)
        if len(unpacked) > 40_000_000 or not decoder.eof:
            raise ValueError("Identidad demasiado grande o dañada.")
        manifest = verify(json.loads(unpacked))
        doc = safe_xml(archive.read("word/document.xml"))
        for forbidden in ["ins", "del", "moveFrom", "moveTo", "tbl", "drawing", "object", "fldSimple", "fldChar", "footnoteReference", "endnoteReference", "numPr"]:
            if doc.find(".//w:" + forbidden, NS) is not None:
                raise ValueError("Se detectaron cambios controlados, listas automáticas, tablas u objetos no reversibles. Acepta/rechaza las revisiones y conserva texto simple dentro de los bloques.")
        if any(re.match(r"word/(header|footer|footnotes|endnotes)\d*\.xml$", n) for n in archive.namelist()):
            raise ValueError("Las cabeceras, pies y notas añadidos no se pueden devolver al proyecto.")
    actual = []
    values = {}
    originals = {r['key']: r for r in manifest['records']}
    expected_fields = {r['key'] + ':' + f for r in manifest['records'] for f in r['fields']}
    baseline_digest = hashlib.sha256(canonical(manifest)).hexdigest()
    pending_copy = None
    copy_count = 0
    body = doc.find("w:body", NS)
    for node in body:
        if node.tag == wtag("sectPr"):
            continue
        if node.tag == wtag("p"):
            text = paragraph_text(node)
            if manifest.get('projection') == 'branch' and not text:
                continue
            actual.append(("fixed", text))
        elif node.tag == wtag("sdt"):
            tag = node.find("w:sdtPr/w:tag", NS)
            if tag is None:
                raise ValueError("Se ha perdido una marca de identidad.")
            key = tag.get(wtag("val"))
            if key in values:
                if manifest.get('projection') != 'branch' or not expected_fields.issubset(values):
                    raise ValueError('El bloque copiado está intercalado entre los originales. Añade el apartado nuevo al final del documento, o reorganízalo en cosmoSys.')
                source_key, field = key.rsplit(':', 1)
                source = originals.get(source_key)
                if not source or source.get('parent') not in originals or any(r.get('parent') == source_key for r in originals.values()):
                    raise ValueError('Para añadir por copia, copia un apartado sin subapartados, con su título y texto. No copies la raíz ni una rama completa.')
                if field == 'subject' and pending_copy is None:
                    copy_count += 1
                    newkey = 'new:' + hashlib.sha256((baseline_digest + ':' + str(copy_count)).encode()).hexdigest()
                    newrecord = copy.deepcopy(source)
                    newrecord.update(key=newkey, creation={'source':source_key, 'parent':source['parent']}, fields={})
                    manifest['records'].append(newrecord)
                    pending_copy = (source_key, newrecord)
                elif field != 'description' or pending_copy is None or pending_copy[0] != source_key:
                    raise ValueError('La copia está incompleta. Copia juntos el título y el texto del apartado.')
                key = pending_copy[1]['key'] + ':' + field
            content = node.find("w:sdtContent", NS)
            if content is None or any(child.tag != wtag("p") for child in content):
                raise ValueError("Un bloque contiene estructura no admitida.")
            values[key] = "\n".join(paragraph_text(p) for p in content)
            if key.startswith('new:'):
                field = key.rsplit(':', 1)[1]
                pending_copy[1]['fields'][field] = values[key]
                if field == 'description':
                    pending_copy = None
            actual.append(("field", key))
        else:
            raise ValueError("Estructura de documento no admitida.")
    if pending_copy:
        raise ValueError('Falta el texto del apartado copiado. Copia juntos su título y su texto.')
    # Only appending siblings at the end is supported; reject an apparent append
    # that would actually belong earlier in the tree's depth-first traversal.
    if copy_count:
        last = list(originals.values())[-1]
        previous_depth = last['depth']
        ancestors = set()
        while last.get('parent') in originals:
            ancestors.add(last['parent'])
            last = originals[last['parent']]
        for r in manifest['records']:
            if r.get('creation') and r['parent'] not in ancestors:
                raise ValueError('El nuevo apartado no quedaría al final de su rama. Exporta solo la rama de su padre y repite la copia allí.')
            if r.get('creation'):
                if r['depth'] > previous_depth:
                    raise ValueError('Las copias no siguen el orden de la rama. Añade primero los apartados más profundos o reorganiza en cosmoSys.')
                previous_depth = r['depth']
    validate_structure(manifest, actual, values)
    return manifest, values


def validate_structure(manifest, actual, values):
    expected = [("field", value[0]) if kind == "field" else ("fixed", value)
                for kind, value in layout(manifest)]
    # Word can add a final empty paragraph after the last content control.
    if actual and actual[-1] == ("fixed", "") and len(actual) == len(expected) + 1:
        actual.pop()
    if actual != expected:
        raise ValueError("Cambió el orden, una cabecera o la identidad de los bloques. Modifica sólo su texto interior.")
    if set(values) != {v for k, v in expected if k == "field"}:
        raise ValueError("Faltan bloques o hay bloques nuevos.")


def read_txt(path):
    manifest = verify(json.loads(Path(str(path) + ".identidad.json").read_text(encoding="utf-8")))
    lines = Path(path).read_text(encoding="utf-8-sig").splitlines()
    actual, values = [], {}
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("[[CS-BEGIN "):
            match = re.fullmatch(r"\[\[CS-BEGIN ([a-z]+:\d+:[a-z_]+)\]\]", line)
            if not match:
                raise ValueError("Marca TXT dañada.")
            key = match[1]
            i += 1
            text = []
            while i < len(lines) and lines[i] != f"[[CS-END {key}]]":
                if lines[i].startswith("[[CS-"):
                    raise ValueError("Marcas TXT incompletas o anidadas.")
                text.append(lines[i]); i += 1
            if i == len(lines) or key in values:
                raise ValueError("Bloque TXT incompleto o duplicado.")
            values[key] = "\n".join(text)
            actual.append(("field", key))
        else:
            actual.append(("fixed", line))
        i += 1
    validate_structure(manifest, actual, values)
    return manifest, values


def read_document(path):
    return read_docx(path) if Path(path).suffix.lower() == ".docx" else read_txt(path)


def plan(manifest, values):
    changes = []
    for record in manifest["records"]:
        if record.get('creation'):
            after = {f: values[record['key'] + ':' + f] for f in ('subject', 'description')}
            if not after['subject'].strip():
                raise ValueError('El apartado nuevo necesita un título.')
            changes.append({'key':record['key'], 'create':record['creation'], 'before':{}, 'after':after})
            continue
        before, after = {}, {}
        for field, original in record["fields"].items():
            new = values[record["key"] + ":" + field]
            if original != new:
                if field not in record["editable"]:
                    raise ValueError("Se modificó un campo de solo lectura: " + record["label"] + " / " + LABELS[field])
                before[field], after[field] = original, new
        if after:
            changes.append({"key": record["key"], "revision": record["revision"], "before": before, "after": after})
    return changes


def apply_document(path, commit=False):
    manifest, values = read_document(path)
    changes = plan(manifest, values)
    if not changes:
        return {"changed": [], "dry_run": not commit}
    if commit:
        backup = ROOT / "recuperacion"
        backup.mkdir(exist_ok=True)
        digest = hashlib.sha256(canonical({"manifest": manifest, "changes": changes})).hexdigest()
        (backup / (digest + ".json")).write_bytes(canonical({"manifest": manifest, "changes": changes}))
    return server(manifest["service"], manifest["project"]["identifier"],
                  "apply" if commit else "check", changes)
