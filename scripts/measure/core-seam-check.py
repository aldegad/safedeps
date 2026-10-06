#!/usr/bin/env python3
"""safedeps: what the core's shared modules print, against the tools the bash
hooks use.

The hooks being moved to Rust share a few modules: the digests, a JSON writer,
how a file's times and inodes are spelled, the stamp that ties a binary to its
source, and the structure the inert rewrite reads. Each has to print what the
bash hooks' own tools print, because the other hook, the engines and the
batteries read those bytes. This asks the binary and the tools the same
questions and compares:

  - `safedeps-core kat` against hashlib, jq, lib/gates/backstop-trace.sh (stat,
    ls -di), realpath and bash's ${#s};
  - `safedeps-core stamp` against the same digest scheme written here, with
    two controls (a byte added to the source, the source removed);
  - `safedeps-core words` on a few texts in each reading: every word's span
    stands in its statement in order, every word reads back as the pieces
    view's word, and every mapped payload byte is the byte it names.

It judges texts and runs none: the texts go to the lexer on stdin.

Usage, from the tree's root: scripts/measure/core-seam-check.py <safedeps-core>
The binary has to stand where its stamp finds rust/ (in the tree, at most
five directories below its root).
"""
import subprocess, hashlib, os, re, sys, tempfile, shutil, time, platform
if len(sys.argv) != 2:
    sys.exit(__doc__)
core = os.path.abspath(sys.argv[1])
bad = 0
def sh(args, inp=b'', env=None, cwd=None):
    p = subprocess.run(args, input=inp, capture_output=True, env=env, cwd=cwd)
    return p.returncode, p.stdout, p.stderr
def check(name, got, want):
    global bad
    ok = got == want
    if not ok: bad += 1
    print(('ok   ' if ok else 'DIFF ') + name + ('' if ok else '\n   core: %r\n   want: %r' % (got, want)))
print('start:', sh(['uptime'])[1].decode().strip())
print('version', sh([core, 'version'])[1])

# ---- stamp
rc, out, _ = sh([core, 'stamp']); kind, digest = out.decode().split()
files = ['Cargo.lock', 'Cargo.toml', 'build.rs']
for d, _, fs in os.walk('rust/src'):
    for f in fs:
        if f.endswith('.rs'): files.append(os.path.relpath(os.path.join(d, f), 'rust'))
h = hashlib.sha256()
for rel in sorted(files, key=lambda s: s.encode()):
    b = open(os.path.join('rust', rel), 'rb').read()
    h.update(rel.encode() + b'\0' + str(len(b)).encode() + b'\0' + b)
check('stamp digest is the scheme over rust/ (%d files, kind %s)' % (len(files), kind), digest, h.hexdigest())
check('stamp --check beside its source', sh([core, 'stamp', '--check'])[:2], (0, b'ok\n'))
T = tempfile.mkdtemp(prefix='seam-stamp.')
try:
    os.makedirs(T + '/bin/native/x-y'); shutil.copy2(core, T + '/bin/native/x-y/safedeps-core')
    shutil.copytree('rust', T + '/rust', ignore=shutil.ignore_patterns('target'))
    c2 = T + '/bin/native/x-y/safedeps-core'
    check('installed layout, same source', sh([c2, 'stamp', '--check'])[:2], (0, b'ok\n'))
    open(T + '/rust/src/pre.rs', 'ab').write(b'\n')
    rc, out, _ = sh([c2, 'stamp', '--check'])
    check('control: one byte added to the source', (rc, b'built from another source' in out), (1, True))
    shutil.rmtree(T + '/rust')
    rc, out, _ = sh([c2, 'stamp', '--check'])
    check('control: no source beside a checkout build', (rc, b'cannot read the source' in out), (1, True))
finally:
    shutil.rmtree(T, ignore_errors=True)

# ---- known answers
T = tempfile.mkdtemp(prefix='seam-kat.')
T = os.path.realpath(T)
try:
    f = T + '/f'; open(f, 'w').close(); os.symlink('f', T + '/l'); os.symlink('nowhere', T + '/dangling'); os.mkdir(T + '/dir')
    uni = T + '/h한éz'; open(uni, 'w').close()
    def kat(path=None, env=None):
        rc, out, err = sh([core, 'kat'] + ([path] if path else []), env=env)
        d = {}
        for line in out.split(b'\n'):
            if line:
                k, _, v = line.partition(b' '); d[k.decode()] = v
        return d
    k = kat()
    million = b'a' * 1000000
    check('md5', k['md5'], hashlib.md5(b'abc').hexdigest().encode())
    check('md5 of nothing', k['md5-empty'], hashlib.md5(b'').hexdigest().encode())
    check('md5 of a million a', k['md5-million-a'], hashlib.md5(million).hexdigest().encode())
    check('sha256', k['sha256'], hashlib.sha256(b'abc').hexdigest().encode())
    check('sha256 of nothing', k['sha256-empty'], hashlib.sha256(b'').hexdigest().encode())
    check('sha256 of a million a', k['sha256-million-a'], hashlib.sha256(million).hexdigest().encode())
    x = b'a\x01b\x7fc\x1bd"e\\f/g<h>i&j\tk\nl\rm\x08n\x0co'
    check('jq escapes', k['jq-escapes'], sh(['jq', '-nc', '--arg', 'x', x, '{x:$x}'])[1].rstrip(b'\n'))
    for name, y in (('jq-invalid', b'h\xed\x95\x9c \xff \xc3 z'), ('jq-invalid-tail', b'a\xe2\x82 b\xf0\x9f\x98')):
        check(name, k[name], sh(['jq', '-nc', '--arg', 'y', y, '$y'])[1].rstrip(b'\n'))
    pretty = sh(['jq', '-n', '--arg', 's', 'x', '--argjson', 't', 'null', '{snapshot_id:$s,n:1,npm_trace:$t,o:{},arr:[],arr2:[1,"a"],nested:{a:{b:1}},ok:true,tool_use_id:null}'])[1].rstrip(b'\n').replace(b'\n', b'|')
    check('jq pretty', k['jq-pretty'], pretty)
    check('jq deny', k['jq-deny'], sh(['jq', '-nc', '--arg', 'r', 'a "b"\n<c>', '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'])[1].rstrip(b'\n'))
    for name, n in (('utc-0', 0), ('utc-leap', 951782400), ('utc-2026', 1791291940)):
        check(name, k[name], time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(n)).encode())
    check('subsecond', k['subsecond'], b'1 0 0')
    lib = 'source lib/gates/backstop-trace.sh; '
    for p in (f, T + '/l', T + '/dangling', T + '/dir', T + '/missing', T + '/missing/deeper', uni):
        kk = kat(p)
        nm = os.path.basename(p)
        check('tree clock of ' + nm, kk['clock-c'], sh(['bash', '-c', lib + 'safedeps_tree_clock "$1"', '_', p])[1])
        check('file clock m of ' + nm, kk['clock-m'], sh(['bash', '-c', lib + 'safedeps_file_clock "$1" m', '_', p])[1].rstrip(b'\n'))
        check('file clock m follow of ' + nm, kk['clock-m-follow'], sh(['bash', '-c', lib + 'safedeps_file_clock "$1" m follow', '_', p])[1].rstrip(b'\n'))
        check('tree inode of ' + nm, kk['inode'], sh(['bash', '-c', lib + 'safedeps_tree_inode "$1"', '_', p])[1])
        check('realpath of ' + nm, kk['realpath'], sh(['bash', '-c', 'realpath "$1" 2>/dev/null || printf %s "$1"', '_', p])[1].rstrip(b'\n'))
    utf = 'en_US.UTF-8' if platform.system() == 'Darwin' else 'C.UTF-8'
    for lang in ('C', utf):
        env = {'PATH': os.environ['PATH'], 'LANG': lang}
        check('bash length under LANG=' + lang, kat(uni, env)['bash-len'], sh(['bash', '-c', 'printf %s "${#1}"', '_', uni], env=env)[1])
finally:
    shutil.rmtree(T, ignore_errors=True)

# ---- words: the structure, and its contract with the pieces view
TEXTS = [
    b'npm ci',
    b'FOO=1 npm install "a b" --cache x >log 2>&1',
    b"echo $(npm ci) && sh -c 'npm i left-pad' ; eval \"npm ci\"",
    b'x=$( { npm ci --ignore-scripts=false} )',
    b"echo `npm ci`; npm install $'a\\x41b' '' \"\"",
    b'(npm ci) | cat; { npm i; }',
    b'sh -c "npm ci \\"x\\" $(echo y)"',
    b'echo $(( $(npm ci) ))',
    b'cat <<E\n$(npm ci)\nE\nnpm install x',
    b'if true; then>/dev/null npm ci; fi',
    b'npm install \'(x)\' a\\ b {c} "t\tu"',
    b"echo `echo \\`npm ci\\``",
]
def words(text, reading):
    rc, out, err = sh([core, 'words'], inp=text, env={'PATH': os.environ['PATH'], 'SAFEDEPS_READING': reading})
    return rc, out
def parse(out):
    i = 0; res = {'P': [], 'Y': []}
    def line():
        nonlocal i
        j = out.index(b'\n', i); l = out[i:j]; i = j + 1; return l
    def take(n):
        nonlocal i
        b = out[i:i + n]; i += n + 1; return b
    while i < len(out):
        l = line().split(b' ')
        if l[0] == b'P': res['P'].append({'nn': int(l[1]), 'start': int(l[2]), 'end': int(l[3]), 'n': int(l[4]), 'words': []})
        elif l[0] == b'W': res['P'][-1]['words'].append((int(l[1]), int(l[2]), take(int(l[3]))))
        elif l[0] == b'V': res['V'] = take(int(l[1]))
        elif l[0] == b'Y': res['Y'].append([l[1], take(int(l[2])), None])
        elif l[0] == b'S': res['Y'][-1][2] = l[1:]
        else: res[l[0].decode()] = l[1:]
    return res
FOLD = set(b' \t\n(){}\x1e\x1f')
for t in TEXTS:
    for rd in ('bash', 'zsh', 'dash'):
        rc, out = words(t, rd)
        if rc != 0:
            print('words rc %d %s %r' % (rc, rd, t)); bad += 1; continue
        r = parse(out)
        if rd == 'bash':
            print('--- %r' % t)
            for p in r['P']:
                print('   P%d [%d,%d) %r' % (p['nn'], p['start'], p['end'], t[p['start']:p['end']]))
                for (a, z, v) in p['words']:
                    print('      W [%d,%d) %r = %r' % (a, z, t[a:z], v))
            for (kind, y, src) in r['Y']:
                print('   Y %s %r src %s' % (kind.decode(), y, b' '.join(src).decode()))
        # contract
        view = {}
        for l in r['V'].split(b'\n'):
            f = l.split(b'\x1f')
            if len(f) == 5: view[int(f[0])] = f
        for p in r['P']:
            prev = p['start']
            for (a, z, v) in p['words']:
                if not (p['start'] <= a < z <= p['end'] and a >= prev):
                    print('   SPAN out of order or outside its statement: %r %s' % (t, rd)); bad += 1
                prev = z
            f = view.get(p['nn'])
            if f is None:
                print('   NO VIEW LINE for piece %d: %r %s' % (p['nn'], t, rd)); bad += 1; continue
            folded = [b'' if (len(v) == 1 and v[0] in FOLD) else bytes(32 if b in FOLD else b for b in v) for (_, _, v) in p['words']]
            # the view's prefix-free words, cut where the view writes a blank or an
            # operator (the walk's separators print as themselves); \002 alone is an empty word
            vw = [b'' if w == b'\x02' else w.replace(b'\x02', b' ') for w in re.split(rb'[ \t()<>;&|]+', f[3]) if w]
            if folded != vw:
                bad += 1
                print('   WORDS differ from the view (%s): %r\n      spans %r\n      view  %r' % (rd, t, folded, vw))
        for (kind, y, src) in r['Y']:
            for b, s in zip(y, src):
                if s != b'-' and t[int(s)] != b:
                    print('   SRC maps to another byte: %r %s' % (t, rd)); bad += 1
            if len(src) != len(y):
                print('   SRC length differs: %r %s' % (t, rd)); bad += 1
print('end:', sh(['uptime'])[1].decode().strip())
print('core-seam-check: %d differ' % bad)
sys.exit(1 if bad else 0)
