"""Deterministic base academic formatting; not a complete APA paper generator."""
import zipfile
from xml.etree import ElementTree as E

W='http://schemas.openxmlformats.org/wordprocessingml/2006/main'
def tag(name):return '{'+W+'}'+name


def set_property(parent, name, attributes):
    """Replace rather than accumulate OOXML properties on repeated formatting."""
    for old in parent.findall(tag(name)):parent.remove(old)
    return E.SubElement(parent,tag(name),{tag(k):v for k,v in attributes.items()})


def apply_base_format(path):
    with zipfile.ZipFile(path) as archive:
        parts={name:archive.read(name) for name in archive.namelist()}
    document=E.fromstring(parts['word/document.xml'])
    for margins in document.iter(tag('pgMar')):
        for side in ('top','bottom','left','right'):margins.set(tag(side),'1440')
    styles=E.fromstring(parts['word/styles.xml'])
    for fonts in styles.iter(tag('rFonts')):
        for attr in ('ascii','hAnsi','eastAsia','cs'):fonts.set(tag(attr),'Times New Roman')
    for size in styles.iter(tag('sz')):size.set(tag('val'),'24')
    for spacing in styles.iter(tag('spacing')):
        for key,value in {'before':'0','after':'0','line':'480','lineRule':'auto'}.items():spacing.set(tag(key),value)
    for style in styles.findall(tag('style')):
        identity=style.get(tag('styleId'))
        props=style.find(tag('pPr'))
        if props is None:props=E.SubElement(style,tag('pPr'))
        set_property(props,'ind',{'firstLine':'720' if identity=='Normal' else '0'})
        set_property(props,'jc',{'val':'center' if identity in ('Title','Heading1') else 'left'})
        # pPr schema places outlineLvl after indentation and alignment.
        for outline in props.findall(tag('outlineLvl')):
            props.remove(outline);props.append(outline)
        if identity in ('Heading1','Heading2','Heading3'):
            run=style.find(tag('rPr'))
            if run is None:run=E.SubElement(style,tag('rPr'))
            set_property(run,'b',{'val':'1'})
            set_property(run,'i',{'val':'1' if identity=='Heading3' else '0'})
            # rPr schema orders bold/italic before font size.
            for name in ('sz','szCs'):
                for size in run.findall(tag(name)):
                    run.remove(size);run.append(size)
    parts['word/document.xml']=E.tostring(document,encoding='utf-8',xml_declaration=True)
    parts['word/styles.xml']=E.tostring(styles,encoding='utf-8',xml_declaration=True)
    with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(parts):
            info=zipfile.ZipInfo(name,(2000,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED
            archive.writestr(info,parts[name])
