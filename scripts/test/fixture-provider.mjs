#!/usr/bin/env node
import http from 'node:http';
import fs from 'node:fs';

const portFile = process.argv[2];
const stateFile = process.argv[3];

if (!portFile || !stateFile) {
  console.error('usage: fixture-provider.mjs <port-file> <state-file>');
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

function osvVuln(id, fixed) {
  const events = [{ introduced: '0' }];
  if (fixed) events.push({ fixed });
  return {
    id,
    aliases: [id],
    affected: [
      {
        package: { ecosystem: 'npm', name: 'fixture' },
        ranges: [{ type: 'SEMVER', events }]
      }
    ]
  };
}

function osvResponse(packageName, version) {
  const key = `${packageName}@${version}`;
  const current = state();
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
  if (req.method === 'POST' && req.url === '/osv/v1/query') {
    const body = await readJson(req);
    const packageName = body.package?.name || '';
    const version = body.version || '';
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify(osvResponse(packageName, version)));
    return;
  }

  if (req.method === 'POST' && req.url === '/osv/v1/querybatch') {
    const body = await readJson(req);
    const queries = Array.isArray(body.queries) ? body.queries : [];
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({
      results: queries.map((query) => osvResponse(query.package?.name || '', query.version || ''))
    }));
    return;
  }

  if (req.method === 'GET' && req.url === '/kev.json') {
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

server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
