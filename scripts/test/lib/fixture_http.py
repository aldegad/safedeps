"""safedeps: the loopback HTTP server under the test fixtures.

fixture-provider.py and fixture-registry.py answer through this module. It
takes each connection with a blocking accept() and reads it in a thread of its
own with blocking recv(). Nothing here waits on a readiness notification: no
epoll, poll or select, and no socket timeout either, because CPython waits in
poll() before each recv() on a socket that has one.

The reason is that a blocking recv() returns when the bytes arrive and needs
no report from the kernel that the socket is ready. A server that waits for
that report reads a request only once it comes. If it never comes, the request
sits unread until the client gives up, and the row fails because of the
fixture, not the gate. The accept() loop is this module's own for the same
reason: socketserver's serve_forever() waits in a selector before each
accept().

A fixture given a trace file appends one line per event of each connection:
`<wall seconds> <pid> <event> <peer port> ...`. The events are listen, accept,
request, body, answer and close. SIGUSR2 writes a `poke` line with the number
of connections the server holds. A client that records its own local port and
times can then be set beside the trace.
"""
import argparse
import http.server
import os
import signal
import socket
import threading
import time
import traceback


def arguments(usage, positional, optional):
    """The fixture's command line: the named positional arguments, then one
    optional one, then `--mark <text>`.

    The mark only names the process to a sweep that reads `ps` (the child
    markers of e2e.sh and lib/npm-sandbox.sh); the server reads nothing from
    it. It is an argument because `exec -a` does not carry it: on macOS the
    python3 on PATH starts another executable, which takes its own name."""
    parser = argparse.ArgumentParser(usage=usage)
    for name in positional:
        parser.add_argument(name)
    parser.add_argument(optional, nargs='?')
    parser.add_argument('--mark')
    return parser.parse_args()


class Trace:
    """One line per event, each written with a single write() to a file
    opened for append, so lines from several threads and from the signal
    handler never interleave and no lock is held."""

    def __init__(self, path):
        self._fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o666) if path else None

    def line(self, *fields):
        if self._fd is None:
            return
        text = '%.3f %d %s\n' % (time.time(), os.getpid(), ' '.join(str(field) for field in fields))
        os.write(self._fd, text.encode())


class Answer:
    def __init__(self, status, payload, content_type=None):
        self.status = status
        self.payload = payload if isinstance(payload, bytes) else payload.encode()
        self.content_type = content_type


def _exchange_class(route, trace):
    class Exchange(http.server.BaseHTTPRequestHandler):
        # HTTP/1.1, so a request with `Expect: 100-continue` is told to go on
        # at once, as node's server does, and a connection stays open for the
        # next request until the client closes it.
        protocol_version = 'HTTP/1.1'

        def log_message(self, *args):
            pass

        def _body(self):
            if self.headers.get('transfer-encoding', '').strip().lower() == 'chunked':
                chunks = []
                while True:
                    size = int(self.rfile.readline().split(b';')[0].strip(), 16)
                    if size == 0:
                        while self.rfile.readline() not in (b'\r\n', b'\n', b''):
                            pass
                        return b''.join(chunks)
                    chunks.append(self.rfile.read(size))
                    self.rfile.readline()
            length = int(self.headers.get('content-length') or 0)
            return self.rfile.read(length) if length > 0 else b''

        def _exchange(self):
            peer = self.client_address[1]
            trace.line('request', peer, self.command, self.path.split('?')[0],
                       self.headers.get('content-length') or '-', self.headers.get('expect') or '-')
            body = self._body()
            trace.line('body', peer)
            answer = route(self.command, self.path, body)
            self.send_response(answer.status)
            if answer.content_type:
                self.send_header('content-type', answer.content_type)
            self.send_header('content-length', str(len(answer.payload)))
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(answer.payload)
            trace.line('answer', peer, answer.status)

        do_GET = do_POST = do_HEAD = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = _exchange

    return Exchange


def serve(route, port_file, trace_file):
    """Listen on 127.0.0.1 at a port the kernel picks, write the port to
    port_file, and answer each request with route(method, url, body), which
    returns an Answer. Runs until the process is killed."""
    trace = Trace(trace_file)
    exchange = _exchange_class(route, trace)
    held = [0]
    held_lock = threading.Lock()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.settimeout(None)
    listener.bind(('127.0.0.1', 0))
    listener.listen(511)
    port = listener.getsockname()[1]
    trace.line('listen', port)
    if trace_file:
        # The handler runs in this thread, after accept() returns EINTR, and
        # accept() is then called again (PEP 475).
        signal.signal(signal.SIGUSR2, lambda *_: trace.line('poke', held[0]))

    def connection(conn, peer):
        clean = True
        try:
            exchange(conn, peer, None)
        except ConnectionError:
            # The client went away: the trace's `close ... error` says so.
            clean = False
        except Exception:
            # Anything else is the fixture's own fault, and the battery's log
            # shows it.
            clean = False
            traceback.print_exc()
        finally:
            try:
                conn.close()
            finally:
                with held_lock:
                    held[0] -= 1
                trace.line('close', peer[1], 'clean' if clean else 'error')

    # The port file appears whole: a battery reads it as soon as it is not
    # empty.
    staged = port_file + '.' + str(os.getpid())
    with open(staged, 'w') as handle:
        handle.write(str(port))
    os.replace(staged, port_file)

    while True:
        conn, peer = listener.accept()
        conn.settimeout(None)
        with held_lock:
            held[0] += 1
        trace.line('accept', peer[1])
        threading.Thread(target=connection, args=(conn, peer), daemon=True).start()
