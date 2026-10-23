"""Explicit integration check for a disposable Redmine with synthetic users only.

Usage: python validate_redmine.py URL PROJECT PRIVATE_KEYS_JSON
Keys JSON: editor (wiki writer API key), reader (read-only wiki API key).
Leaves uniquely named synthetic pages for inspection; never run on production.
"""
import json
import sys
import uuid
from pathlib import Path
from urllib.error import HTTPError
from publication import Publisher, RedmineWiki, Conflict


def main():
    url,project,keyfile=sys.argv[1:]
    keys=json.loads(Path(keyfile).read_text())
    writer=RedmineWiki(url,keys['editor'])
    reader=RedmineWiki(url,keys['reader'])
    service=Publisher({'test':(writer,{project})})
    payload=dict(destination='test',project=project,text='Synthetic review: ñ, accents and\nsecond line.',request_id=uuid.uuid4().hex)
    preview=service.preview(payload)
    path='/projects/'+project+'/wiki/'+preview['page']+'.json'
    try:
        writer.request(path)
        raise AssertionError('Preview unexpectedly wrote a page')
    except HTTPError as e:
        assert e.code==404,e.code
    def commit(p):
        return service.commit(dict(review_token=p['review_token'],content_sha256=p['content_sha256'],confirmed=True))
    assert commit(preview)['reused'] is False
    assert commit(preview)['reused'] is True
    page=writer.request(path)['wiki_page']
    assert page['text']==payload['text']
    version=page['version']
    changed=service.preview(dict(payload,text='Conflicting synthetic content'))
    try:
        commit(changed)
        raise AssertionError('Conflict was accepted')
    except Conflict: pass
    assert writer.request(path)['wiki_page']['version']==version
    assert reader.request(path)['wiki_page']['text']==payload['text']
    try:
        reader.publish(project,preview['page']+'_denied','Not permitted')
        raise AssertionError('Read-only user wrote a page')
    except HTTPError as e:
        assert e.code in (401,403),e.code
    print('PASS: preview has no write; exact text; retry without extra revision; conflict preserves data; reader can read but cannot create.')


if __name__=='__main__': main()
