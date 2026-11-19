#!/usr/bin/env node
// A loopback stand-in for every source the watch reads, driven by a state file
// the battery rewrites between runs (scripts/test/watch.sh): OSV query,
// querybatch and records, the KEV catalog, GHSA, the OpenJDK advisories index
// and pages, and the Adoptium API. querybatch answers as OSV does, with ids and
// `modified` only, so a reader that needs fixed versions has to read the record.
// It gives `modified` to the microsecond, as OSV does: a record's fraction past
// six digits is cut, not rounded (measured on OSV on 2026-11-19, record
// `…51.191256883Z`, batch `…51.191256Z`), and a time with six digits or fewer is
// given as it is.
//
//   node watch-fixture.mjs <port-file> <state-file> <request-log>
//
// The state file is read on every request. Its fields:
//   osv:      {"<pkg>@<version>": [<OSV record>, ...]}
//   down:     ["osv", "kev", "openjdk", "adoptium"]   sources that answer 503
//   kev:      ["CVE-..."]
//   openjdk:  [{date, affected: "21.0.13, 17.0.21, 8u504"}]
//   adoptium: {"21": {release_name, timestamp, release_link, version_data}}
// Every request is appended to the request log as one JSON line, with the
// number of provider requests in flight when it arrived.
import http from 'node:http';
import fs from 'node:fs';

const [portFile, stateFile, requestLog] = process.argv.slice(2);
if (!portFile || !stateFile || !requestLog) {
  console.error('usage: watch-fixture.mjs <port-file> <state-file> <request-log>');
  process.exit(2);
}

let inFlight = 0;
const state = () => JSON.parse(fs.readFileSync(stateFile, 'utf8'));
const down = (s, name) => (s.down || []).includes(name);

function body(req) {
  return new Promise((resolve) => {
    let text = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => { text += chunk; });
    req.on('end', () => { try { resolve(JSON.parse(text || '{}')); } catch { resolve({}); } });
  });
}

function send(res, status, payload, type = 'application/json') {
  res.writeHead(status, { 'content-type': type });
  res.end(typeof payload === 'string' ? payload : JSON.stringify(payload));
}

function records(s, name, version) {
  return (s.osv || {})[`${name}@${version}`] || [];
}

function allRecords(s) {
  return Object.values(s.osv || {}).flat();
}

function toMicroseconds(time) {
  return time.replace(/(\.[0-9]{6})[0-9]+Z$/, '$1Z');
}

const server = http.createServer(async (req, res) => {
  inFlight += 1;
  const s = state();
  const url = new URL(req.url, 'http://fixture');
  const delay = Number(s.delay_ms || 0);
  fs.appendFileSync(requestLog, `${JSON.stringify({ method: req.method, path: url.pathname, in_flight: inFlight })}\n`);
  try {
    if (delay > 0) await new Promise((r) => setTimeout(r, delay));
    if (url.pathname === '/osv/v1/query' && req.method === 'POST') {
      if (down(s, 'osv')) return send(res, 503, { error: 'down' });
      const q = await body(req);
      const vulns = records(s, q.package?.name || '', q.version || '');
      return send(res, 200, vulns.length ? { vulns } : {});
    }
    if (url.pathname === '/osv/v1/querybatch' && req.method === 'POST') {
      if (down(s, 'osv')) return send(res, 503, { error: 'down' });
      const q = await body(req);
      const results = (q.queries || []).map((query) => {
        const vulns = records(s, query.package?.name || '', query.version || '');
        return vulns.length ? { vulns: vulns.map((v) => ({ id: v.id, modified: toMicroseconds(v.modified || '2026-01-01T00:00:00Z') })) } : {};
      });
      return send(res, 200, { results });
    }
    if (url.pathname.startsWith('/osv/v1/vulns/') && req.method === 'GET') {
      if (down(s, 'osv')) return send(res, 503, { error: 'down' });
      const id = decodeURIComponent(url.pathname.slice('/osv/v1/vulns/'.length));
      const record = allRecords(s).find((v) => v.id === id);
      return record ? send(res, 200, record) : send(res, 404, { code: 5, message: 'Bug not found.' });
    }
    if (url.pathname === '/kev.json') {
      if (down(s, 'kev')) return send(res, 503, { error: 'down' });
      const ids = s.kev && s.kev.length ? s.kev : ['CVE-2000-0001'];
      return send(res, 200, { vulnerabilities: ids.map((cveID) => ({ cveID })) });
    }
    if (url.pathname.startsWith('/advisories')) {
      return send(res, 200, []);
    }
    if (url.pathname === '/openjdk/' || url.pathname === '/openjdk') {
      if (down(s, 'openjdk')) return send(res, 503, 'down', 'text/html');
      const links = (s.openjdk || []).map((a) => `<li><a href="${a.date}">${a.date.replaceAll('-', '/')}</a></li>`).join('\n');
      return send(res, 200, `<html><body><p>third Tuesday of January, April, July and October</p><ul>\n${links}\n</ul></body></html>`, 'text/html');
    }
    if (url.pathname.startsWith('/openjdk/')) {
      if (down(s, 'openjdk')) return send(res, 503, 'down', 'text/html');
      const date = url.pathname.slice('/openjdk/'.length);
      const advisory = (s.openjdk || []).find((a) => a.date === date);
      if (!advisory) return send(res, 404, 'none', 'text/html');
      return send(res, 200, `<html><body><p>The following vulnerabilities in OpenJDK source code were fixed
in this release. The affected versions are ${advisory.affected}, and earlier. Please
note that defense-in-depth issues are not assigned CVEs.</p></body></html>`, 'text/html');
    }
    const feature = url.pathname.match(/^\/adoptium\/v3\/assets\/feature_releases\/(\d+)\/ga$/);
    if (feature) {
      if (down(s, 'adoptium')) return send(res, 503, { error: 'down' });
      const release = (s.adoptium || {})[feature[1]];
      return release ? send(res, 200, [release]) : send(res, 404, { error: 'no release' });
    }
    return send(res, 404, { error: 'no route' });
  } finally {
    inFlight -= 1;
  }
});

server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});

// The battery that started this server is its parent. A battery killed with
// SIGKILL runs no trap, and the server, reparented, would serve forever.
const parent = process.ppid;
setInterval(() => {
  if (process.ppid !== parent) process.exit(0);
}, 1000);
