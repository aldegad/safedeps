#!/usr/bin/env node
// A minimal npm registry on 127.0.0.1 for the end-to-end install tests.
//
// It serves a packument and a tarball for every `<name>-<version>.tgz` in a
// directory, next to the `<name>-<version>.tgz.json` manifest it was packed
// from. Tarball URLs are written as registry.npmjs.org URLs on purpose: npm's
// default `replace-registry-host=npmjs` fetches them from the configured
// registry (this server), and the lockfile records the canonical URL, as it
// does for a real install. So the lockfile heuristics in post-verify see an
// ordinary lockfile rather than one pointing at a local port.
//
// Every request is appended to a log, so a test can show nothing left the
// machine.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [portFile, tarDir, logFile] = process.argv.slice(2);

if (!portFile || !tarDir || !logFile) {
  console.error('usage: fixture-registry.mjs <port-file> <tarball-dir> <request-log>');
  process.exit(2);
}

function packument(name) {
  const versions = {};
  for (const file of fs.readdirSync(tarDir)) {
    const match = file.match(/^(.+)-(\d+\.\d+\.\d+)\.tgz$/);
    if (!match || match[1] !== name) continue;
    const tarball = fs.readFileSync(path.join(tarDir, file));
    const manifest = JSON.parse(fs.readFileSync(path.join(tarDir, `${file}.json`), 'utf8'));
    versions[match[2]] = {
      ...manifest,
      _id: `${name}@${match[2]}`,
      dist: {
        tarball: `https://registry.npmjs.org/${name}/-/${file}`,
        shasum: crypto.createHash('sha1').update(tarball).digest('hex'),
        integrity: `sha512-${crypto.createHash('sha512').update(tarball).digest('base64')}`
      }
    };
  }
  const list = Object.keys(versions).sort();
  if (list.length === 0) return null;
  return { name, versions, 'dist-tags': { latest: list[list.length - 1] } };
}

const server = http.createServer((req, res) => {
  fs.appendFileSync(logFile, `${req.method} ${req.url}\n`);
  const url = decodeURIComponent(req.url.split('?')[0]);
  const tarball = url.match(/^\/(.+)\/-\/([^/]+\.tgz)$/);
  if (tarball) {
    const file = path.join(tarDir, tarball[2]);
    if (fs.existsSync(file)) {
      res.setHeader('content-type', 'application/octet-stream');
      res.end(fs.readFileSync(file));
      return;
    }
  } else {
    const doc = packument(url.slice(1));
    if (doc) {
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify(doc));
      return;
    }
  }
  res.statusCode = 404;
  res.end('{}');
});

server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
