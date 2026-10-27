#!/usr/bin/env python3
"""Copy Temporal's Elasticsearch visibility index from Railway to AWS.

Copies the index mapping, then every document with its _id and _version
(external versioning, the same way Temporal writes them), then checks that
both sides hold the same number of documents.

Credentials come from the environment, not the command line:
  SOURCE_ES_URL  e.g. http://elastic:<password>@<railway-tcp-proxy>:<port>
  TARGET_ES_URL  e.g. http://elastic:<password>@elasticsearch.postiz.internal:9200

Usage:
  es-copy-index.py --index temporal_visibility_v1_dev [--batch 2000] [--recreate]

Stops if the source changes while it is copied (Temporal still running on
Railway); FORCE=1 downgrades that to a warning for rehearsals.

Standard library only, so it runs in any python:3 image.
"""
import argparse
import base64
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--index', required=True)
    ap.add_argument('--batch', type=int, default=2000)
    ap.add_argument('--recreate', action='store_true', help='delete the target index first if it already has documents')
    ap.add_argument('--insecure', action='store_true', help='skip TLS verification (self-signed clusters)')
    args = ap.parse_args()

    src_url, dst_url = os.environ.get('SOURCE_ES_URL'), os.environ.get('TARGET_ES_URL')
    if not src_url or not dst_url:
        sys.exit('SOURCE_ES_URL and TARGET_ES_URL must be set')
    src, dst = ES(src_url, args.insecure), ES(dst_url, args.insecure)
    index = args.index

    status, info = src.call('GET', f'/{index}')
    if status != 200:
        sys.exit(f'source index {index} not found on {src.base}: {status} {info}')
    meta = info[index]
    source_total = count(src, index)
    source_running = count(src, index, RUNNING)
    print(f'source {src.base}/{index}: {source_total} documents, {source_running} running workflows')

    status, existing = dst.call('GET', f'/{index}', ok=(200, 404))
    if status == 200:
        target_total = count(dst, index)
        if target_total and not args.recreate:
            sys.exit(f'target index already has {target_total} documents, rerun with --recreate to replace it')
        dst.call('DELETE', f'/{index}')
        print(f'deleted existing target index ({target_total} documents)')

    index_settings = {k: v for k, v in meta['settings']['index'].items() if k not in GENERATED_SETTINGS}
    # single node on AWS: replicas would leave the index yellow forever
    index_settings['number_of_replicas'] = '0'
    status, body = dst.call('PUT', f'/{index}', {'settings': {'index': index_settings}, 'mappings': meta['mappings']})
    if status not in (200, 201):
        sys.exit(f'creating target index failed: {status} {body}')
    print('target index created with the source mapping')

    # templates too, so an index Temporal creates later matches
    for kind in ('_index_template', '_template'):
        status, templates = src.call('GET', f'/{kind}/temporal*', ok=(200, 404))
        if status != 200:
            continue
        items = templates.get('index_templates') if kind == '_index_template' else [{'name': k, 'index_template': v} for k, v in templates.items()]
        for t in items or []:
            dst.call('PUT', f'/{kind}/{t["name"]}', t['index_template'])
            print(f'copied {kind} {t["name"]}')

    copied = 0
    status, page = src.call('POST', f'/{index}/_search?scroll=5m&version=true', {'size': args.batch, 'sort': ['_doc']})
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
        status, res = dst.call('POST', '/_bulk', '\n'.join(lines) + '\n', ndjson=True)
        if status != 200:
            sys.exit(f'bulk failed: {status} {res}')
        if res.get('errors'):
            failed = [i for i in res['items'] if i['index'].get('error')]
            sys.exit(f'{len(failed)} documents failed, first: {failed[0]["index"]["error"]}')
        copied += len(page['hits']['hits'])
        print(f'copied {copied}/{source_total}', flush=True)
        status, page = src.call('POST', '/_search/scroll', {'scroll': '5m', 'scroll_id': scroll_id})
        if status != 200:
            sys.exit(f'scroll failed: {status} {page}')
        scroll_id = page.get('_scroll_id', scroll_id)
    src.call('DELETE', '/_search/scroll', {'scroll_id': scroll_id}, ok=(200, 404))

    # nothing may write to the source while it is copied: a moving source means
    # Temporal still runs on Railway and the copy is already stale
    if count(src, index) != source_total or count(src, index, RUNNING) != source_running:
        message = 'the source index changed during the copy. Stop all four Temporal services on Railway, then rerun with --recreate'
        if os.environ.get('FORCE') != '1':
            sys.exit(f'STOP: {message}')
        print(f'WARNING (FORCE=1): {message}')
        return

    target_total = count(dst, index)
    target_running = count(dst, index, RUNNING)
    print(f'target {dst.base}/{index}: {target_total} documents, {target_running} running workflows')
    if target_total != source_total or target_running != source_running:
        sys.exit(f'MISMATCH: source {source_total}/{source_running} vs target {target_total}/{target_running}')
    print('OK: counts match')


if __name__ == '__main__':
    main()
