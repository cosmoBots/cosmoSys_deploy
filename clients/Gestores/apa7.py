"""Deterministic student-paper publication with signed, reversible text fields."""
import base64
import copy
import hashlib
import json
import re
import tempfile
import zipfile
import zlib
from pathlib import Path
from xml.etree import ElementTree as E
import bridge
from academic_format import apply_base_format, tag, set_property

R='http://schemas.openxmlformats.org/officeDocument/2006/relationships'
REL='http://schemas.openxmlformats.org/package/2006/relationships'
CT='http://schemas.openxmlformats.org/package/2006/content-types'
FIELDS=('author','affiliation','course','instructor','due_date')
LABELS={'author':'Autor pendiente','affiliation':'Institución pendiente','course':'Asignatura pendiente',
        'instructor':'Tutor pendiente','due_date':'Fecha de entrega pendiente'}
ROLES=('body','abstract','references','block_quote','exclude')

def check_settings(data):
    if not isinstance(data,dict) or set(data)-set(FIELDS)-{'paper_size','instructor_provisional'}:
        raise ValueError('Metadatos de portada incorrectos.')
    for key in FIELDS:
        if not isinstance(data.get(key,''),str) or len(data.get(key,''))>1000:
            raise ValueError('Campo de portada incorrecto: '+key)
    if data.get('paper_size','letter') not in ('letter','a4'):raise ValueError('Papel desconocido.')
    if not isinstance(data.get('instructor_provisional',False),bool):raise ValueError('Estado de tutor incorrecto.')
    return data

def prepare(manifest,notes,settings):
    check_settings(settings)
    m=copy.deepcopy(manifest); selected=[]; excluded=set(); warnings=[]
    for rec in m['records']:
        role=notes.get(rec['key'],{}).get('data',{}).get('export_role','body')
        if role not in ROLES:raise ValueError('Tipo de apartado desconocido.')
        if role=='exclude' or rec.get('parent') in excluded:
            excluded.add(rec['key']);continue
        if rec.get('depth',0)>5:raise ValueError('APA admite cinco niveles: reorganiza la rama antes de exportar.')
        rec['academic_role']=role;selected.append(rec)
        if '|' in rec['fields']['description']:warnings.append('Posible tabla en texto: '+rec['fields']['subject'])
        if role=='references' and any(line.strip() and not re.search(r'\((?:\d{4}[a-z]?|s\.\s?f\.)\)',line) for line in rec['fields']['description'].split('\n')):
            warnings.append('La sección de referencias contiene notas o entradas sin fecha reconocible; revisarlas antes de entregar.')
        if re.search(r'no incluir|aviso editorial',rec['fields']['subject'],re.I):warnings.append('Revisa la inclusión del material editorial: '+rec['fields']['subject'])
    if not selected or selected[0]['key']!=m['root']:raise ValueError('No se puede excluir la raíz del documento.')
    m['records']=selected
    warnings[:0]=[LABELS[k] for k in FIELDS if not settings.get(k,'').strip()]
    if settings.get('instructor_provisional'):warnings.append('Tutor provisional: confirmar antes de entregar.')
    warnings.append('Comprobar citas, referencias, contenido científico y requisitos propios de la universidad.')
    return m,list(dict.fromkeys(warnings)),len(excluded)

def paragraph(text,style='Normal',bold=False,italic=False):
    p=bridge.paragraph(text,style)
    if style=='APAReference':
        # Unambiguous journal/volume pattern only; do not guess book/source titles.
        match=re.search(r'\.\s+([^\.\n]+),\s+(\d+)(?:\([^)]*\))?,\s+(?:\d+[–-]\d+|\d+)(?:\.|\s)',text)
        if match:
            for run in p.findall(tag('r')):p.remove(run)
            spans=[(0,match.start(1),False),(match.start(1),match.end(2),True),(match.end(2),len(text),False)]
            for start,end,emphasis in spans:
                run=E.SubElement(p,tag('r'))
                if emphasis:E.SubElement(E.SubElement(run,tag('rPr')),tag('i'))
                E.SubElement(run,tag('t'),{'{http://www.w3.org/XML/1998/namespace}space':'preserve'}).text=text[start:end]
    if bold or italic:
        for run in p.findall(tag('r')):
            props=E.Element(tag('rPr'));run.insert(0,props)
            if bold:E.SubElement(props,tag('b'))
            if italic:E.SubElement(props,tag('i'))
    return p

def properties(p):
    props=p.find(tag('pPr'))
    if props is None:props=E.Element(tag('pPr'));p.insert(0,props)
    return props

def control(identity,paragraphs,inline=False):
    s=E.Element(tag('sdt'));props=E.SubElement(s,tag('sdtPr'))
    E.SubElement(props,tag('tag'),{tag('val'):identity})
    E.SubElement(props,tag('id'),{tag('val'):str(int(hashlib.sha256(identity.encode()).hexdigest()[:7],16))})
    E.SubElement(props,tag('lock'),{tag('val'):'sdtLocked'})
    content=E.SubElement(s,tag('sdtContent'))
    for p in paragraphs:
        if inline:
            for run in p.findall(tag('r')):content.append(run)
        else:content.append(p)
    return s

def write(manifest,notes,settings,path):
    m,warnings,excluded=prepare(manifest,notes,settings)
    # Base package supplies deterministic styles and common exchange namespaces.
    bridge.write_docx(m,path);apply_base_format(path)
    with zipfile.ZipFile(path) as archive:parts={n:archive.read(n) for n in archive.namelist()}
    doc=E.fromstring(parts['word/document.xml']);body=doc.find(tag('body'))
    sect=body.find(tag('sectPr'));body.clear();segments=[]
    def fixed(identity,ps):
        segments.append({'id':identity,'fixed':[bridge.paragraph_text(p) for p in ps]})
        return control(identity,ps)
    def field(key,text,style='Normal',inline=False,bold=False,italic=False):
        identity='apa:'+str(len(segments))
        segments.append({'id':identity,'field':key,'display':text})
        return control(identity,[paragraph(line,style,bold,italic) for line in text.split('\n')],inline)
    title=m['records'][0]['fields']['subject']
    cover=[paragraph('', 'APACover') for _ in range(3)]+[paragraph(title,'APACover',bold=True),paragraph('','APACover')]
    for key in FIELDS:
        value=settings.get(key,'').strip() or '['+LABELS[key]+']'
        if key=='instructor' and settings.get('instructor_provisional'):value+=' (provisional)'
        cover.append(paragraph(value,'APACover'))
    body.append(fixed('apa:cover',cover))
    first=True
    for rec in m['records']:
        depth=rec['depth'];role=rec['academic_role'];key=rec['key'];subject=rec['fields']['subject']
        # Publication-only numbering removal; baseline text is kept in signed manifest.
        heading=subject if depth==0 else re.sub(r'^\s*\d+(?:\.\d+)*[.)]?\s+','',subject)
        style='Title' if depth==0 else 'Heading'+str(depth)
        if role in ('abstract','references'):style='Heading1'
        # Empty source lines are paragraph separators, not additional APA spacing.
        # The signed original is returned unchanged when the displayed text is unchanged.
        lines=[line for line in rec['fields']['description'].split('\n') if line.strip()] or ['']
        # Do not alphabetize mixed editorial notes as if they were citations.
        if role=='references' and all(re.search(r'\((?:\d{4}[a-z]?|s\.\s?f\.)\)',line) for line in lines):
            lines=sorted(lines,key=str.casefold)
        if depth in (4,5) and role=='body':
            p=E.Element(tag('p'));E.SubElement(properties(p),tag('pStyle'),{tag('val'):'APAInline'})
            body.append(p)
            p.append(field(key+':subject',heading,inline=True,bold=True,italic=depth==5))
            sep='' if heading.endswith('.') else '.'
            # Formatting punctuation is fixed, never written into the source title.
            p.append(fixed('apa:separator:'+key,[paragraph(sep+' ')]))
            separator=p[-1];content=separator.find(tag('sdtContent'));para=content[0];content.remove(para)
            for run in para: 
                if run.tag==tag('r'):content.append(run)
            p.append(field(key+':description',lines[0],inline=True))
            if len(lines)>1:body.append(field(key+':description','\n'.join(lines[1:])))
        else:
            head=field(key+':subject',heading,style)
            if first or role in ('abstract','references'):
                E.SubElement(properties(head.find('.//'+tag('p'))),tag('pageBreakBefore'))
            body.append(head)
            textstyle={'abstract':'APAAbstract','references':'APAReference','block_quote':'APAQuote'}.get(role,'Normal')
            body.append(field(key+':description','\n'.join(lines),textstyle))
        first=False
    # Existing reviewed reference notes are a separate fixed appendix, not invented citations.
    refs=sorted({n['data']['reference'].strip() for k,n in notes.items()
                 if k in {r['key'] for r in m['records']} and n.get('data',{}).get('reference','').strip()},key=str.casefold)
    if refs:
        ps=[paragraph('Referencias','Heading1')]
        E.SubElement(properties(ps[0]),tag('pageBreakBefore'))
        ps += [paragraph(r,'APAReference') for r in refs]
        body.append(fixed('apa:references',ps))
    body.append(sect)
    E.SubElement(sect,tag('pgNumType'),{tag('start'):'1'})
    if settings.get('paper_size','letter')=='a4':
        sect.find(tag('pgSz')).attrib.update({tag('w'):'11906',tag('h'):'16838'})
    sect.find(tag('pgMar')).set(tag('header'),'720')
    sect.insert(0,E.Element(tag('headerReference'),{tag('type'):'default','{'+R+'}id':'rIdAPAHeader'}))
    header=E.Element(tag('hdr'));p=paragraph('','APAHeader');header.append(p)
    fieldpage=E.SubElement(p,tag('fldSimple'),{tag('instr'):' PAGE '})
    run=E.SubElement(fieldpage,tag('r'));E.SubElement(run,tag('t')).text='1'
    parts['word/header1.xml']=bridge.xml(header)
    rels=E.fromstring(parts['word/_rels/document.xml.rels'])
    E.SubElement(rels,'{'+REL+'}Relationship',{'Id':'rIdAPAHeader','Type':R+'/header','Target':'header1.xml'})
    parts['word/_rels/document.xml.rels']=bridge.xml(rels)
    types=E.fromstring(parts['[Content_Types].xml'])
    E.SubElement(types,'{'+CT+'}Override',{'PartName':'/word/header1.xml','ContentType':'application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml'})
    parts['[Content_Types].xml']=bridge.xml(types)
    styles=E.fromstring(parts['word/styles.xml'])
    for name,align,indent in [('APACover','center',{}),('APAHeader','right',{}),('APAAbstract','left',{}),
                              ('APAReference','left',{'left':'720','hanging':'720'}),('APAQuote','left',{'left':'720'}),
                              ('APAInline','left',{'firstLine':'720'})]:
        s=E.SubElement(styles,tag('style'),{tag('type'):'paragraph',tag('styleId'):name})
        E.SubElement(s,tag('name'),{tag('val'):name});E.SubElement(s,tag('basedOn'),{tag('val'):'Normal'})
        props=E.SubElement(s,tag('pPr'))
        ind=indent if 'firstLine' in indent or 'hanging' in indent else dict(firstLine='0',**indent)
        E.SubElement(props,tag('ind'),{tag(k):v for k,v in ind.items()})
        E.SubElement(props,tag('jc'),{tag('val'):align})
    parts['word/styles.xml']=bridge.xml(styles);parts['word/document.xml']=bridge.xml(doc)
    m['academic_export']={'version':1,'segments':segments,'settings':settings}
    custom=E.fromstring(parts['docProps/custom.xml']);custom[0][0].text=base64.b64encode(zlib.compress(bridge.canonical(bridge.sign(m)),9)).decode()
    parts['docProps/custom.xml']=bridge.xml(custom)
    with zipfile.ZipFile(path,'w') as archive:
        for name in sorted(parts):
            info=zipfile.ZipInfo(name,(2000,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED
            archive.writestr(info,parts[name])
    return {'warnings':warnings,'excluded':excluded}

def read(path):
    """Academic importer: validates frozen material; only editable fields return."""
    with zipfile.ZipFile(path) as archive:
        if len(archive.infolist())>1000 or sum(i.file_size for i in archive.infolist())>100_000_000:raise ValueError('Documento demasiado grande.')
        custom=bridge.safe_xml(archive.read('docProps/custom.xml'))
        matches=[n for n in custom if n.get('name')=='CosmosysTextExchange']
        if len(matches)!=1:raise ValueError('Identidad ausente.')
        decoder=zlib.decompressobj();raw=decoder.decompress(base64.b64decode(matches[0][0].text,validate=True),40_000_001)
        if len(raw)>40_000_000 or not decoder.eof:raise ValueError('Identidad dañada.')
        m=bridge.verify(json.loads(raw))
        if 'academic_export' not in m:return bridge.read_docx(path)
        doc=bridge.safe_xml(archive.read('word/document.xml'))
        for name in ('ins','del','moveFrom','moveTo','tbl','drawing','object','fldSimple','fldChar','footnoteReference','endnoteReference','numPr'):
            if doc.find('.//'+tag(name)) is not None:raise ValueError('El Word contiene objetos o revisiones no reversibles; conserva texto dentro de los bloques.')
        extras=[n for n in archive.namelist() if re.match(r'word/(header|footer|footnotes|endnotes)\d*\.xml$',n)]
        if 'word/header1.xml' not in extras or set(extras)-{'word/header1.xml','word/footnotes.xml','word/endnotes.xml'}:raise ValueError('Cabeceras/notas no reconocidas.')
        for name in set(extras)-{'word/header1.xml'}:
            notes=bridge.safe_xml(archive.read(name))
            allowed={tag(x) for x in ('footnotes','footnote','endnotes','endnote','p','pPr','spacing','r','separator','continuationSeparator')}
            if any(n.tag not in allowed for n in notes.iter()) or any(n.get(tag('type')) not in ('separator','continuationSeparator') for n in notes):raise ValueError('Las notas añadidas no se importan; intégralas en un apartado.')
        hdr=bridge.safe_xml(archive.read('word/header1.xml'));fields=list(hdr.iter(tag('fldSimple')))
        instructions=''.join(n.text or '' for n in hdr.iter(tag('instrText'))).strip()
        marks=[n.get(tag('fldCharType')) for n in hdr.iter(tag('fldChar'))]
        simple=len(fields)==1 and fields[0].get(tag('instr'),'').strip()=='PAGE' and not instructions and not marks
        complex_page=not fields and instructions=='PAGE' and marks==['begin','separate','end']
        if not (simple or complex_page):raise ValueError('Se alteró la paginación.')
        if any(hdr.find('.//'+tag(n)) is not None for n in ('drawing','object','tbl','ins','del','hyperlink')):raise ValueError('Cabecera con contenido no admitido.')
        visible=''.join(n.text or '' for n in hdr.iter(tag('t')))
        if not re.fullmatch(r'\d+',visible):raise ValueError('La cabecera contiene texto que no se importaría.')
    actual=[]
    def scan(container):
        for node in container:
            if node.tag==tag('sdt'):
                marker=node.find('w:sdtPr/w:tag',bridge.NS)
                if marker is None:raise ValueError('Bloque sin identidad.')
                content=node.find(tag('sdtContent'))
                if content is None:raise ValueError('Bloque vacío.')
                if all(c.tag==tag('p') for c in content):texts=[bridge.paragraph_text(c) for c in content]
                elif all(c.tag in (tag('r'),tag('proofErr')) for c in content):
                    p=E.Element(tag('p'));p.extend(content);texts=[bridge.paragraph_text(p)]
                else:raise ValueError('Estructura no admitida dentro del bloque.')
                actual.append((marker.get(tag('val')),texts))
            elif node.tag==tag('p'):
                if any(c.tag==tag('sdt') for c in node):
                    if any(c.tag not in (tag('pPr'),tag('sdt'),tag('proofErr')) for c in node):raise ValueError('Texto añadido fuera de los bloques.')
                    scan(node)
                elif bridge.paragraph_text(node):raise ValueError('Texto añadido fuera de los bloques.')
            elif node.tag not in (tag('sectPr'),tag('pPr'),tag('proofErr')):raise ValueError('Estructura no admitida.')
    scan(doc.find(tag('body')))
    plan=m['academic_export']['segments']
    if [x[0] for x in actual]!=[s['id'] for s in plan]:raise ValueError('Se ha cambiado el orden o identidad de los bloques APA. Reorganiza en el gestor.')
    fragments={};baseline={}
    for (_,texts),segment in zip(actual,plan):
        if 'fixed' in segment:
            if texts!=segment['fixed']:raise ValueError('Portada, puntuación o bibliografía generada cambiada: edítala en el gestor y vuelve a exportar.')
        else:
            fragments.setdefault(segment['field'],[]).append('\n'.join(texts))
            baseline.setdefault(segment['field'],[]).append(segment['display'])
    originals={r['key']+':'+f:text for r in m['records'] for f,text in r['fields'].items()}
    values={key:originals[key] if chunks==baseline[key] else '\n'.join(chunks) for key,chunks in fragments.items()}
    if set(values)!=set(originals):raise ValueError('Campos incompletos.')
    return m,values
