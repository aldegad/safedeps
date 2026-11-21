// safedeps: what a fixture server saw, and when.
//
// A fixture server that is given a trace file appends one line per event of
// each connection: `<wall seconds> <pid> <event> <peer port> ...`. The events
// are listen, accept, request, body, answer and close. A client that records
// its own local port and times can then be set beside it: a connection the
// server never accepted, one it accepted and never read, and one it answered
// late each leave a different set of lines.
//
// Tracing adds no timer and no listener that changes how a request is read:
// a timer would wake the event loop, and a loop that only wakes on a timer is
// one of the things the trace is there to show.
import fs from 'node:fs';

export function traceServer(server, file) {
  if (!file) return;
  const fd = fs.openSync(file, 'a');
  const line = (...fields) => fs.writeSync(fd, `${(Date.now() / 1000).toFixed(3)} ${process.pid} ${fields.join(' ')}\n`);
  server.on('listening', () => line('listen', server.address().port));
  server.on('connection', (socket) => {
    const peer = socket.remotePort;
    line('accept', peer);
    socket.on('close', (hadError) => line('close', peer, hadError ? 'error' : 'clean'));
  });
  server.prependListener('request', (req, res) => {
    const peer = req.socket.remotePort;
    line('request', peer, req.method, req.url.split('?')[0], req.headers['content-length'] || '-', req.headers.expect || '-');
    req.on('end', () => line('body', peer));
    res.on('finish', () => line('answer', peer, res.statusCode));
  });
  // SIGUSR2 writes a line with the connections the server holds. A signal
  // ends the event loop's wait, so a connection the loop was never told of is
  // accepted right after this line, and one the loop already holds is not.
  process.on('SIGUSR2', () => server.getConnections((error, count) => line('poke', error ? 'error' : count)));
}
