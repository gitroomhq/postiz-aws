#!/usr/bin/env python3
"""Copy Temporal's Elasticsearch visibility index from Railway to AWS.

Copies the index settings and mapping and the temporal* templates, then every
document with its _id and _version (external versioning, the same way Temporal
writes them), then checks that the target holds exactly the documents read,
running workflows included.

Credentials come from the environment, not the command line:
  SOURCE_ES_URL  e.g. http://elastic:<password>@elasticsearch.railway.internal:9200
  TARGET_ES_URL  e.g. http://elastic:<password>@elasticsearch.postiz.internal:9200

Usage:
  es-copy-index.py --index temporal_visibility_v1_dev [--batch 2000] [--recreate]   source -> target
  es-copy-index.py --index temporal_visibility_v1_dev --export DIR                  source -> DIR
  es-copy-index.py --import DIR [--recreate]                                       DIR -> target

The direct copy needs one machine that reaches both clusters. Without an open
port, --export runs inside the Railway project and --import in the AWS ops
task; scripts/migration-transfer.sh carries DIR (meta.json, docs.ndjson.gz)
between them.

Stops if the source changes while it is read (Temporal still running on
Railway); FORCE=1 downgrades that to a warning for rehearsals.

Standard library only, so it runs in any python:3 image.
"""
import argparse
import base64
import gzip
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit, unquote

# settings Elasticsearch generates itself; sending them back on create fails
GENERATED_SETTINGS = {'uuid', 'version', 'creation_date', 'provided_name', 'routing', 'resize', 'history'}


class ES:
    def __init__(self, url, insecure):
        parts = urlsplit(url)
        if not parts.scheme or not parts.hostname:
            sys.exit(f'invalid Elasticsearch URL (expected http(s)://user:pass@host:port): {parts.scheme}://{parts.hostname}')
        self.base = f'{parts.scheme}://{parts.hostname}:{parts.port or (443 if parts.scheme == "https" else 9200)}'
        self.auth = None
        if parts.username:
            token = f'{unquote(parts.username)}:{unquote(parts.password or "")}'.encode()
            self.auth = 'Basic ' + base64.b64encode(token).decode()
        self.ctx = ssl._create_unverified_context() if insecure else None

    def call(self, method, path, body=None, ndjson=False, ok=(200, 201)):
        data = None
        headers = {}
        if body is not None:
            data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
            headers['Content-Type'] = 'application/x-ndjson' if ndjson else 'application/json'
        if self.auth:
            headers['Authorization'] = self.auth
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=120, context=self.ctx) as res:
                    raw = res.read()
                    return res.status, (json.loads(raw) if raw else {})
            except urllib.error.HTTPError as e:
                raw = e.read()
                if e.code in ok:
                    return e.code, (json.loads(raw) if raw else {})
                if e.code in (429, 502, 503, 504) and attempt < 4:
                    time.sleep(2 ** attempt)
                    continue
                return e.code, (json.loads(raw) if raw else {})
            except urllib.error.URLError:
                if attempt < 4:
                    time.sleep(2 ** attempt)
                    continue
                raise
        raise RuntimeError('unreachable')


def count(es, index, query=None):
    es.call('POST', f'/{index}/_refresh')
    status, body = es.call('POST', f'/{index}/_count', {'query': query} if query else None)
    if status != 200:
        sys.exit(f'count failed on {es.base}/{index}: {status} {body}')
    return body['count']


# what Postiz looks up before deleting or rescheduling a post
RUNNING = {'term': {'ExecutionStatus': 'Running'}}


def read_index(src, index):
    """Settings, mapping and templates of the source index."""
    status, info = src.call('GET', f'/{index}')
    if status != 200:
        sys.exit(f'source index {index} not found on {src.base}: {status} {info}')
    templates = []
    # templates too, so an index Temporal creates later matches
    for kind in ('_index_template', '_template'):
        status, found = src.call('GET', f'/{kind}/temporal*', ok=(200, 404))
        if status != 200:
            continue
        items = found.get('index_templates') if kind == '_index_template' else [{'name': k, 'index_template': v} for k, v in found.items()]
        templates += [{'kind': kind, 'name': t['name'], 'body': t['index_template']} for t in items or []]
    return {
        'index': index,
        'settings': {k: v for k, v in info[index]['settings']['index'].items() if k not in GENERATED_SETTINGS},
        'mappings': info[index]['mappings'],
        'templates': templates,
    }


def read_documents(src, meta, batch):
    """One _bulk body per scroll page; counts the documents (and running workflows) read into meta."""
    index = meta['index']
    meta['documents'] = meta['running'] = 0
    status, page = src.call('POST', f'/{index}/_search?scroll=5m&version=true', {'size': batch, 'sort': ['_doc']})
    if status != 200:
        sys.exit(f'scroll failed: {status} {page}')
    scroll_id = page.get('_scroll_id')
    while page['hits']['hits']:
        lines = []
        for hit in page['hits']['hits']:
            action = {'_index': index, '_id': hit['_id']}
            if '_version' in hit:
                action.update({'version': hit['_version'], 'version_type': 'external'})
            lines.append(json.dumps({'index': action}))
            lines.append(json.dumps(hit['_source']))
            meta['running'] += hit['_source'].get('ExecutionStatus') == 'Running'
        meta['documents'] += len(page['hits']['hits'])
        yield '\n'.join(lines) + '\n'
        status, page = src.call('POST', '/_search/scroll', {'scroll': '5m', 'scroll_id': scroll_id})
        if status != 200:
            sys.exit(f'scroll failed: {status} {page}')
        scroll_id = page.get('_scroll_id', scroll_id)
    src.call('DELETE', '/_search/scroll', {'scroll_id': scroll_id}, ok=(200, 404))


def check_frozen(src, meta, before):
    """Nothing may write to the source while it is read: a moving source means
    Temporal still runs on Railway and the copy is already stale."""
    index = meta['index']
    after = (count(src, index), count(src, index, RUNNING))
    if after == before == (meta['documents'], meta['running']):
        return
    message = (f'the source index changed while it was read (documents/running: {before[0]}/{before[1]} before, '
               f'{meta["documents"]}/{meta["running"]} read, {after[0]}/{after[1]} after). '
               'Stop all four Temporal services on Railway, then run this again')
    if os.environ.get('FORCE') != '1':
        sys.exit(f'STOP: {message}')
    print(f'WARNING (FORCE=1): {message}')


def prepare_target(dst, meta, recreate):
    index = meta['index']
    status, _ = dst.call('GET', f'/{index}', ok=(200, 404))
    if status == 200:
        existing = count(dst, index)
        if existing and not recreate:
            sys.exit(f'target index already has {existing} documents, rerun with --recreate to replace it')
        dst.call('DELETE', f'/{index}')
        print(f'deleted existing target index ({existing} documents)')
    settings = dict(meta['settings'])
    # single node on AWS: replicas would leave the index yellow forever
    settings['number_of_replicas'] = '0'
    status, body = dst.call('PUT', f'/{index}', {'settings': {'index': settings}, 'mappings': meta['mappings']})
    if status not in (200, 201):
        sys.exit(f'creating target index failed: {status} {body}')
    print('target index created with the source mapping')
    for t in meta['templates']:
        dst.call('PUT', f'/{t["kind"]}/{t["name"]}', t['body'])
        print(f'copied {t["kind"]} {t["name"]}')


def load(dst, bodies, expected):
    loaded = 0
    for body in bodies:
        status, res = dst.call('POST', '/_bulk', body, ndjson=True)
        if status != 200:
            sys.exit(f'bulk failed: {status} {res}')
        if res.get('errors'):
            failed = [i for i in res['items'] if i['index'].get('error')]
            sys.exit(f'{len(failed)} documents failed, first: {failed[0]["index"]["error"]}')
        loaded += len(res['items'])
        print(f'loaded {loaded}/{expected}', flush=True)


def verify_target(dst, meta):
    index = meta['index']
    total, running = count(dst, index), count(dst, index, RUNNING)
    print(f'target {dst.base}/{index}: {total} documents, {running} running workflows')
    if (total, running) != (meta['documents'], meta['running']):
        sys.exit(f'MISMATCH: {meta["documents"]}/{meta["running"]} read from the source, {total}/{running} in the target')
    print('OK: counts match')


def read_docs_file(path, batch):
    """_bulk bodies of `batch` documents (an action line and a source line each) from an export."""
    with gzip.open(path, 'rt') as f:
        lines = []
        for line in f:
            lines.append(line)
            if len(lines) == 2 * batch:
                yield ''.join(lines)
                lines = []
        if lines:
            yield ''.join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--index')
    ap.add_argument('--batch', type=int, default=2000)
    ap.add_argument('--recreate', action='store_true', help='delete the target index first if it already has documents')
    ap.add_argument('--insecure', action='store_true', help='skip TLS verification (self-signed clusters)')
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument('--export', metavar='DIR', help='write the index to DIR instead of a target cluster')
    mode.add_argument('--import', dest='import_dir', metavar='DIR', help='load an --export directory into the target cluster')
    args = ap.parse_args()

    def cluster(var):
        url = os.environ.get(var)
        if not url:
            sys.exit(f'{var} must be set')
        return ES(url, args.insecure)

    if args.import_dir:
        dst = cluster('TARGET_ES_URL')
        with open(os.path.join(args.import_dir, 'meta.json')) as f:
            meta = json.load(f)
        print(f'import {meta["index"]}: {meta["documents"]} documents, {meta["running"]} running workflows')
        prepare_target(dst, meta, args.recreate)
        load(dst, read_docs_file(os.path.join(args.import_dir, 'docs.ndjson.gz'), args.batch), meta['documents'])
        verify_target(dst, meta)
        return

    if not args.index:
        ap.error('--index is required')
    src = cluster('SOURCE_ES_URL')
    dst = None if args.export else cluster('TARGET_ES_URL')
    meta = read_index(src, args.index)
    before = (count(src, args.index), count(src, args.index, RUNNING))
    print(f'source {src.base}/{args.index}: {before[0]} documents, {before[1]} running workflows')

    if args.export:
        if os.path.isdir(args.export) and os.listdir(args.export):
            sys.exit(f'{args.export} is not empty: export into a new directory')
        os.makedirs(args.export, exist_ok=True)
        with gzip.open(os.path.join(args.export, 'docs.ndjson.gz'), 'wt', compresslevel=3) as f:
            for body in read_documents(src, meta, args.batch):
                f.write(body)
                print(f'read {meta["documents"]}/{before[0]}', flush=True)
        check_frozen(src, meta, before)
        # written last and in one step: an export without meta.json is incomplete
        with open(os.path.join(args.export, 'meta.json.tmp'), 'w') as f:
            json.dump(meta, f)
        os.replace(os.path.join(args.export, 'meta.json.tmp'), os.path.join(args.export, 'meta.json'))
        print(f'exported {meta["documents"]} documents ({meta["running"]} running workflows) to {args.export}')
        return

    prepare_target(dst, meta, args.recreate)
    load(dst, read_documents(src, meta, args.batch), before[0])
    check_frozen(src, meta, before)
    verify_target(dst, meta)


if __name__ == '__main__':
    main()
