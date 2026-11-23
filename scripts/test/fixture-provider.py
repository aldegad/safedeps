#!/usr/bin/env python3
"""A loopback stand-in for OSV, the KEV catalog and GHSA, driven by a state
file the battery rewrites between steps. It answers through lib/fixture_http.py,
which says why it reads with blocking recv().

  fixture-provider.py <port-file> <state-file> [<trace-file>] [--mark <text>]

The trace file, if given, gets each connection's events (lib/fixture_http.py).
"""
import json
import re
import sys
import time
import urllib.parse
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
import fixture_http  # noqa: E402

args = fixture_http.arguments('fixture-provider.py <port-file> <state-file> [<trace-file>] [--mark <text>]',
                              ['port_file', 'state_file'], 'trace_file')


def state():
    with open(args.state_file) as handle:
        return json.load(handle)


def number(value):
    """A state field read as a count of milliseconds: anything that is not a
    number, or a string of one, counts as 0."""
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return 0
    return 0


def text(value):
    """A request field as the query reads it: a missing or empty one is ''."""
    return value if isinstance(value, str) else ('' if not value else str(value))


def field(obj, *keys):
    for key in keys:
        obj = obj.get(key) if isinstance(obj, dict) else None
    return obj


def dumps(value):
    return json.dumps(value, separators=(',', ':'))


# Every record the fixture has, by id. OSV changes a record's `modified` when
# it changes the record; these never change.
MODIFIED = '2026-01-01T00:00:00Z'
RECORDS = {}


def osv_vuln(id_, fixed, aliases=None):
    events = [{'introduced': '0'}]
    if fixed:
        events.append({'fixed': fixed})
    record = {
        'id': id_,
        'modified': MODIFIED,
        'aliases': aliases if aliases is not None else [id_],
        'affected': [{
            'package': {'ecosystem': 'npm', 'name': 'fixture'},
            'ranges': [{'type': 'SEMVER', 'events': events}],
        }],
    }
    RECORDS[id_] = record
    return record


# Every record an answer below names is there from the start, so a record can
# be read before any query has named it.
for _id, _fixed in [('CVE-2026-9999', None), ('CVE-2026-1000', None), ('CVE-2026-1001', '1.0.1'),
                    ('CVE-2026-1002', None), ('CVE-2026-1003', '1.0.1'), ('CVE-2026-1004', '1.0.5')]:
    osv_vuln(_id, _fixed)
# A record whose alias is on the KEV catalog while its id is not: only the
# record says it is listed.
KEV_ALIAS = osv_vuln('GHSA-fixt-kev0-alas', None, ['CVE-2026-9999'])
# Named by querybatch, with no record behind it, or with another record.
RECORD_MISSING = {'id': 'GHSA-fixt-gone-0000', 'modified': MODIFIED}
RECORD_OTHER = {'id': 'GHSA-fixt-othr-0000', 'modified': MODIFIED}
# An advisory OSV changed: querybatch names it at CURRENT, and its record at
# CURRENT carries the KEV-listed CVE. With `serve_stale_record` set in the
# state, /v1/vulns/<id> serves the version before the change instead: same
# id, modified MODIFIED, no KEV alias. That record is not the one querybatch
# named.
CURRENT = '2026-01-02T00:00:00Z'
STALE_ID = 'GHSA-fixt-stal-0000'
STALE_NAMED = {'id': STALE_ID, 'modified': CURRENT}


def stale_record():
    before = state().get('serve_stale_record')
    return {
        'id': STALE_ID,
        'modified': MODIFIED if before else CURRENT,
        'aliases': [STALE_ID] if before else ['CVE-2026-9999'],
        'affected': [{'package': {'ecosystem': 'npm', 'name': 'fixture'},
                      'ranges': [{'type': 'SEMVER', 'events': [{'introduced': '0'}]}]}],
    }


# querybatch gives a `modified` to the microsecond and /v1/vulns/<id> gives
# the same time with nine fraction digits. Measured on OSV on 2026-11-19 for
# GHSA-28wg-ghj8-5hjv: batch `2026-09-10T03:50:51.191256Z`, record
# `2026-09-10T03:50:51.191256883Z`. The batch cuts the digits past the sixth;
# it does not round them, or that pair would end in 257. So the batch
# answers below cut a record's fraction the same way, and a time with six
# digits or fewer is given as it is.
def to_microseconds(time_):
    return re.sub(r'(\.[0-9]{6})[0-9]+Z\Z', r'\1Z', time_) if isinstance(time_, str) else time_


# Two advisories whose records carry nine digits, so querybatch names them
# with six: one KEV lists by its alias and one it does not. With
# `serve_later_record` set in the state, /v1/vulns/<id> serves either record
# one microsecond after the time querybatch named, as after OSV changed it.
# That record is not the one querybatch named.
PRECISE = '2026-09-10T03:50:51.191256883Z'
LATER = '2026-09-10T03:50:51.191257883Z'
PRECISE_IDS = {'GHSA-fixt-prec-0000': ['GHSA-fixt-prec-0000'], 'GHSA-fixt-prek-0000': ['CVE-2026-9999']}


def precise_record(id_):
    return {
        'id': id_,
        'modified': LATER if state().get('serve_later_record') else PRECISE,
        'aliases': PRECISE_IDS[id_],
        'affected': [{'package': {'ecosystem': 'npm', 'name': 'fixture'},
                      'ranges': [{'type': 'SEMVER', 'events': [{'introduced': '0'}]}]}],
    }


# The answer to one query. A package named for it below, or listed under the
# state key of the same name, answers in pages as OSV does (`paged`: a first
# page with next_page_token and the rest asked again with that token), with a
# token that is not one (`bad_token`), with no end (`endless`), or names an
# advisory whose record carries the KEV-listed CVE (`kev_alias`), that has
# no record (`record_missing`), that OSV changed (`stale_record`), or whose
# record carries nine fraction digits (`precise`, and `precise_kev` for the
# one KEV lists by its alias).
def osv_response(package_name, version, page_token):
    key = '%s@%s' % (package_name, version)
    current = state()

    def listed(name):
        return isinstance(current.get(name), list) and key in current[name]

    if package_name == 'fixture-bad-token' or listed('bad_token'):
        return {'vulns': [], 'next_page_token': 7}
    if package_name == 'fixture-endless' or listed('endless'):
        return {'vulns': [], 'next_page_token': 'again'}
    if package_name == 'fixture-kev-alias' or listed('kev_alias'):
        return {'vulns': [KEV_ALIAS]}
    if package_name == 'fixture-record-missing' or listed('record_missing'):
        return {'vulns': [RECORD_MISSING]}
    if package_name == 'fixture-record-other':
        return {'vulns': [RECORD_OTHER]}
    if package_name == 'fixture-stale-record' or listed('stale_record'):
        return {'vulns': [STALE_NAMED]}
    if package_name == 'fixture-precise' or listed('precise'):
        return {'vulns': [{'id': 'GHSA-fixt-prec-0000', 'modified': PRECISE}]}
    if package_name == 'fixture-precise-kev' or listed('precise_kev'):
        return {'vulns': [{'id': 'GHSA-fixt-prek-0000', 'modified': PRECISE}]}
    if (package_name == 'fixture-paged' or listed('paged')) and page_token != 'page-2':
        return {'vulns': [], 'next_page_token': 'page-2'}
    if package_name == 'fixture-paged':
        return {'vulns': [osv_vuln('CVE-2026-1002', None)]}
    if isinstance(current.get('kev'), list) and key in current['kev']:
        return {'vulns': [osv_vuln('CVE-2026-9999', None)]}
    if isinstance(current.get('vulnerable'), list) and key in current['vulnerable']:
        return {'vulns': [osv_vuln('CVE-2026-1000', None)]}
    if package_name == 'fixture-vuln' and version == '1.0.0':
        return {'vulns': [osv_vuln('CVE-2026-1001', '1.0.1')]}
    if package_name == 'fixture-multi-vuln' and version == '1.0.0':
        return {'vulns': [osv_vuln('CVE-2026-1003', '1.0.1'), osv_vuln('CVE-2026-1004', '1.0.5')]}
    if package_name == 'fixture-multi-vuln' and version == '1.0.1':
        return {'vulns': [osv_vuln('CVE-2026-1004', '1.0.5')]}
    if package_name == 'fixture-unpatched':
        return {'vulns': [osv_vuln('CVE-2026-1002', None)]}
    if package_name == 'fixture-kev':
        return {'vulns': [osv_vuln('CVE-2026-9999', None)]}
    return {}


def read_json(body):
    try:
        value = json.loads(body.decode() or '{}')
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def hold(milliseconds):
    if number(milliseconds) > 0:
        time.sleep(number(milliseconds) / 1000)


JSON = 'application/json'


def route(method, url, body):
    # A query string moves no route: a mirror's URL may carry one.
    path = url.split('?')[0]
    if method == 'POST' and path == '/osv/v1/query':
        query = read_json(body)
        answer = osv_response(text(field(query, 'package', 'name')), text(query.get('version')),
                              query.get('page_token'))
        return fixture_http.Answer(200, dumps(answer), JSON)

    if method == 'POST' and path == '/osv/v1/querybatch':
        queries = read_json(body).get('queries')
        queries = queries if isinstance(queries, list) else []

        def named(query):
            return '%s@%s' % (text(field(query, 'package', 'name')), text(field(query, 'version')))

        # A batch that names a package listed under `batch_fails` (name@version)
        # fails whole, as a querybatch OSV could not serve does. A batch that
        # names none of them answers.
        failing = state().get('batch_fails')
        if isinstance(failing, list) and any(named(query) in failing for query in queries):
            return fixture_http.Answer(500, dumps({'code': 13, 'message': 'fixture: this batch fails'}), JSON)
        # A batch is held before it answers: a first page by hold_first_ms, a
        # page asked with a token by hold_next_ms.
        paged = any(field(query, 'page_token') for query in queries)
        hold(state().get('hold_next_ms' if paged else 'hold_first_ms'))
        # querybatch names an advisory by its id and `modified` only, to the
        # microsecond; the record is read from /v1/vulns/<id>.
        results = []
        for query in queries:
            answer = osv_response(text(field(query, 'package', 'name')), text(field(query, 'version')),
                                  field(query, 'page_token'))
            if isinstance(answer.get('vulns'), list):
                answer = dict(answer)
                answer['vulns'] = [{'id': vuln['id'], 'modified': to_microseconds(vuln['modified'])}
                                   for vuln in answer['vulns']]
            results.append(answer)
        return fixture_http.Answer(200, dumps({'results': results}), JSON)

    if method == 'GET' and url.startswith('/osv/v1/vulns/'):
        # A record is held before it answers by hold_record_ms.
        hold(state().get('hold_record_ms'))
        id_ = urllib.parse.unquote(url[len('/osv/v1/vulns/'):])
        if id_ == RECORD_OTHER['id']:
            return fixture_http.Answer(200, dumps(RECORDS.get('CVE-2026-1002') or osv_vuln('CVE-2026-1002', None)), JSON)
        if id_ == STALE_ID:
            return fixture_http.Answer(200, dumps(stale_record()), JSON)
        if id_ in PRECISE_IDS:
            return fixture_http.Answer(200, dumps(precise_record(id_)), JSON)
        record = RECORDS.get(id_)
        if record is None:
            return fixture_http.Answer(404, dumps({'code': 5, 'message': 'Bug not found.'}), JSON)
        return fixture_http.Answer(200, dumps(record), JSON)

    if method == 'GET' and url == '/kev.json':
        # The catalog is held before it answers by hold_kev_ms.
        hold(state().get('hold_kev_ms'))
        return fixture_http.Answer(200, dumps({'vulnerabilities': [{
            'cveID': 'CVE-2026-9999',
            'vendorProject': 'fixture',
            'product': 'fixture-kev',
            'vulnerabilityName': 'Fixture KEV',
        }]}), JSON)

    if method == 'GET' and url.startswith('/advisories'):
        return fixture_http.Answer(200, '[]', JSON)

    return fixture_http.Answer(404, 'not found')


fixture_http.serve(route, args.port_file, args.trace_file)
