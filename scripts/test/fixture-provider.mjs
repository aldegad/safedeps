#!/usr/bin/env node
import http from 'node:http';
import fs from 'node:fs';
import { traceServer } from './lib/fixture-trace.mjs';

const portFile = process.argv[2];
const stateFile = process.argv[3];
// Optional: a file the server appends each connection's events to
// (lib/fixture-trace.mjs).
const traceFile = process.argv[4];

if (!portFile || !stateFile) {
  console.error('usage: fixture-provider.mjs <port-file> <state-file> [<trace-file>]');
  process.exit(2);
}

function readJson(req) {
  return new Promise((resolve) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      body += chunk;
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(body || '{}'));
      } catch {
        resolve({});
      }
    });
  });
}

function state() {
  return JSON.parse(fs.readFileSync(stateFile, 'utf8'));
}

// Every record the fixture has, by id. OSV changes a record's `modified` when
// it changes the record; these never change.
const MODIFIED = '2026-01-01T00:00:00Z';
const RECORDS = new Map();
function osvVuln(id, fixed, aliases = [id]) {
  const events = [{ introduced: '0' }];
  if (fixed) events.push({ fixed });
  const record = {
    id,
    modified: MODIFIED,
    aliases,
    affected: [
      {
        package: { ecosystem: 'npm', name: 'fixture' },
        ranges: [{ type: 'SEMVER', events }]
      }
    ]
  };
  RECORDS.set(id, record);
  return record;
}
// Every record an answer below names is there from the start, so a record can
// be read before any query has named it.
for (const [id, fixed] of [['CVE-2026-9999', null], ['CVE-2026-1000', null], ['CVE-2026-1001', '1.0.1'],
  ['CVE-2026-1002', null], ['CVE-2026-1003', '1.0.1'], ['CVE-2026-1004', '1.0.5']]) {
  osvVuln(id, fixed);
}
// A record whose alias is on the KEV catalog while its id is not: only the
// record says it is listed.
const kevAlias = osvVuln('GHSA-fixt-kev0-alas', null, ['CVE-2026-9999']);
// Named by querybatch, with no record behind it, or with another record.
const recordMissing = { id: 'GHSA-fixt-gone-0000', modified: MODIFIED };
const recordOther = { id: 'GHSA-fixt-othr-0000', modified: MODIFIED };
// An advisory OSV changed: querybatch names it at CURRENT, and its record at
// CURRENT carries the KEV-listed CVE. With `serve_stale_record` set in the
// state, /v1/vulns/<id> serves the version before the change instead: same
// id, modified MODIFIED, no KEV alias. That record is not the one querybatch
// named.
const CURRENT = '2026-01-02T00:00:00Z';
const staleId = 'GHSA-fixt-stal-0000';
const staleNamed = { id: staleId, modified: CURRENT };
function staleRecord() {
  const before = state().serve_stale_record;
  return {
    id: staleId,
    modified: before ? MODIFIED : CURRENT,
    aliases: before ? [staleId] : ['CVE-2026-9999'],
    affected: [{ package: { ecosystem: 'npm', name: 'fixture' }, ranges: [{ type: 'SEMVER', events: [{ introduced: '0' }] }] }]
  };
}

// querybatch gives a `modified` to the microsecond and /v1/vulns/<id> gives
// the same time with nine fraction digits. Measured on OSV on 2026-11-19 for
// GHSA-28wg-ghj8-5hjv: batch `2026-09-10T03:50:51.191256Z`, record
// `2026-09-10T03:50:51.191256883Z`. The batch cuts the digits past the sixth;
// it does not round them, or that pair would end in 257. So the batch
// answers below cut a record's fraction the same way, and a time with six
// digits or fewer is given as it is.
function toMicroseconds(time) {
  return typeof time === 'string' ? time.replace(/(\.[0-9]{6})[0-9]+Z$/, '$1Z') : time;
}
// Two advisories whose records carry nine digits, so querybatch names them
// with six: one KEV lists by its alias and one it does not. With
// `serve_later_record` set in the state, /v1/vulns/<id> serves either record
// one microsecond after the time querybatch named, as after OSV changed it.
// That record is not the one querybatch named.
const PRECISE = '2026-09-10T03:50:51.191256883Z';
const LATER = '2026-09-10T03:50:51.191257883Z';
const preciseIds = new Map([['GHSA-fixt-prec-0000', ['GHSA-fixt-prec-0000']], ['GHSA-fixt-prek-0000', ['CVE-2026-9999']]]);
function preciseRecord(id) {
  return {
    id,
    modified: state().serve_later_record ? LATER : PRECISE,
    aliases: preciseIds.get(id),
    affected: [{ package: { ecosystem: 'npm', name: 'fixture' }, ranges: [{ type: 'SEMVER', events: [{ introduced: '0' }] }] }]
  };
}

// The answer to one query. A package named for it below, or listed under the
// state key of the same name, answers in pages as OSV does (`paged`: a first
// page with next_page_token and the rest asked again with that token), with a
// token that is not one (`bad_token`), with no end (`endless`), or names an
// advisory whose record carries the KEV-listed CVE (`kev_alias`), that has
// no record (`record_missing`), that OSV changed (`stale_record`), or whose
// record carries nine fraction digits (`precise`, and `precise_kev` for the
// one KEV lists by its alias).
function osvResponse(packageName, version, pageToken) {
  const key = `${packageName}@${version}`;
  const current = state();
  const listed = (name) => Array.isArray(current[name]) && current[name].includes(key);
  if (packageName === 'fixture-bad-token' || listed('bad_token')) {
    return { vulns: [], next_page_token: 7 };
  }
  if (packageName === 'fixture-endless' || listed('endless')) {
    return { vulns: [], next_page_token: 'again' };
  }
  if (packageName === 'fixture-kev-alias' || listed('kev_alias')) {
    return { vulns: [kevAlias] };
  }
  if (packageName === 'fixture-record-missing' || listed('record_missing')) {
    return { vulns: [recordMissing] };
  }
  if (packageName === 'fixture-record-other') {
    return { vulns: [recordOther] };
  }
  if (packageName === 'fixture-stale-record' || listed('stale_record')) {
    return { vulns: [staleNamed] };
  }
  if (packageName === 'fixture-precise' || listed('precise')) {
    return { vulns: [{ id: 'GHSA-fixt-prec-0000', modified: PRECISE }] };
  }
  if (packageName === 'fixture-precise-kev' || listed('precise_kev')) {
    return { vulns: [{ id: 'GHSA-fixt-prek-0000', modified: PRECISE }] };
  }
  if ((packageName === 'fixture-paged' || listed('paged')) && pageToken !== 'page-2') {
    return { vulns: [], next_page_token: 'page-2' };
  }
  if (packageName === 'fixture-paged') {
    return { vulns: [osvVuln('CVE-2026-1002', null)] };
  }
  if (current.kev?.includes(key)) {
    return { vulns: [osvVuln('CVE-2026-9999', null)] };
  }
  if (current.vulnerable?.includes(key)) {
    return { vulns: [osvVuln('CVE-2026-1000', null)] };
  }
  if (packageName === 'fixture-vuln' && version === '1.0.0') {
    return { vulns: [osvVuln('CVE-2026-1001', '1.0.1')] };
  }
  if (packageName === 'fixture-multi-vuln' && version === '1.0.0') {
    return {
      vulns: [
        osvVuln('CVE-2026-1003', '1.0.1'),
        osvVuln('CVE-2026-1004', '1.0.5')
      ]
    };
  }
  if (packageName === 'fixture-multi-vuln' && version === '1.0.1') {
    return { vulns: [osvVuln('CVE-2026-1004', '1.0.5')] };
  }
  if (packageName === 'fixture-unpatched') {
    return { vulns: [osvVuln('CVE-2026-1002', null)] };
  }
  if (packageName === 'fixture-kev') {
    return { vulns: [osvVuln('CVE-2026-9999', null)] };
  }
  return {};
}

const server = http.createServer(async (req, res) => {
  // A query string moves no route: a mirror's URL may carry one.
  const path = req.url.split('?')[0];
  if (req.method === 'POST' && path === '/osv/v1/query') {
    const body = await readJson(req);
    const packageName = body.package?.name || '';
    const version = body.version || '';
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify(osvResponse(packageName, version, body.page_token)));
    return;
  }

  if (req.method === 'POST' && path === '/osv/v1/querybatch') {
    const body = await readJson(req);
    const queries = Array.isArray(body.queries) ? body.queries : [];
    // A batch that names a package listed under `batch_fails` (name@version)
    // fails whole, as a querybatch OSV could not serve does. A batch that names
    // none of them answers.
    const failing = state().batch_fails;
    if (Array.isArray(failing)
      && queries.some((query) => failing.includes(`${query.package?.name || ''}@${query.version || ''}`))) {
      res.statusCode = 500;
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ code: 13, message: 'fixture: this batch fails' }));
      return;
    }
    // A batch is held before it answers: a first page by hold_first_ms, a
    // page asked with a token by hold_next_ms.
    const held = state()[queries.some((query) => query.page_token) ? 'hold_next_ms' : 'hold_first_ms'];
    if (Number(held) > 0) await new Promise((resolve) => setTimeout(resolve, Number(held)));
    res.setHeader('content-type', 'application/json');
    // querybatch names an advisory by its id and `modified` only, to the
    // microsecond; the record is read from /v1/vulns/<id>.
    res.end(JSON.stringify({
      results: queries.map((query) => {
        const answer = osvResponse(query.package?.name || '', query.version || '', query.page_token);
        if (!Array.isArray(answer.vulns)) return answer;
        return { ...answer, vulns: answer.vulns.map((vuln) => ({ id: vuln.id, modified: toMicroseconds(vuln.modified) })) };
      })
    }));
    return;
  }

  if (req.method === 'GET' && req.url.startsWith('/osv/v1/vulns/')) {
    // A record is held before it answers by hold_record_ms.
    const heldRecord = Number(state().hold_record_ms);
    if (heldRecord > 0) await new Promise((resolve) => setTimeout(resolve, heldRecord));
    const id = decodeURIComponent(req.url.slice('/osv/v1/vulns/'.length));
    res.setHeader('content-type', 'application/json');
    if (id === recordOther.id) {
      res.end(JSON.stringify(RECORDS.get('CVE-2026-1002') || osvVuln('CVE-2026-1002', null)));
      return;
    }
    if (id === staleId) {
      res.end(JSON.stringify(staleRecord()));
      return;
    }
    if (preciseIds.has(id)) {
      res.end(JSON.stringify(preciseRecord(id)));
      return;
    }
    const record = RECORDS.get(id);
    if (!record) {
      res.statusCode = 404;
      res.end(JSON.stringify({ code: 5, message: 'Bug not found.' }));
      return;
    }
    res.end(JSON.stringify(record));
    return;
  }

  if (req.method === 'GET' && req.url === '/kev.json') {
    // The catalog is held before it answers by hold_kev_ms.
    const heldKev = Number(state().hold_kev_ms);
    if (heldKev > 0) await new Promise((resolve) => setTimeout(resolve, heldKev));
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({
      vulnerabilities: [
        {
          cveID: 'CVE-2026-9999',
          vendorProject: 'fixture',
          product: 'fixture-kev',
          vulnerabilityName: 'Fixture KEV'
        }
      ]
    }));
    return;
  }

  if (req.method === 'GET' && req.url.startsWith('/advisories')) {
    res.setHeader('content-type', 'application/json');
    res.end('[]');
    return;
  }

  res.statusCode = 404;
  res.end('not found');
});

traceServer(server, traceFile);
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
