"""C's frozen native clock observation contract, for archive copies only.

The source catalog pins the entire Rust input, not just the producer's table.
Named mutation edits below are experimental controls and are checked exactly.
No user supplied source hash can extend that allowlist. Unknown sources, changed
tap, missing events, child processes, and ambiguous consumers remain unresolved.
"""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import threading

HERE = Path(__file__).resolve().parent
CATALOG = json.loads((HERE / 'native-catalog.json').read_text())
TAP = (HERE / 'native-tap.rs').read_bytes()
ANCHOR = b'    let raw = std::time::SystemTime::now();\n'
FD = 198
FD_LOCK = threading.Lock()

# Source mutations occur after the raw return and leave the trusted tap intact.
CONTROLS = {
    'snapshot-day': ('rust/src/pre/snapshot.rs',
        b'let timestamp=os::wall(os::WallRole::PreSnapshot).seconds();',
        b'let timestamp=os::wall(os::WallRole::PreSnapshot).seconds()+86400;'),
    'snapshot-borrow': ('rust/src/pre/snapshot.rs',
        b'let timestamp=os::wall(os::WallRole::PreSnapshot).seconds();',
        b'let _original=os::wall(os::WallRole::PreSnapshot); std::thread::sleep(std::time::Duration::from_millis(1100)); let timestamp=os::wall(os::WallRole::StateTempName).seconds();'),
    'snapshot-bypass': ('rust/src/pre/snapshot.rs',
        b'let timestamp=os::wall(os::WallRole::PreSnapshot).seconds();',
        b'let timestamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;'),
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def transform(path, data, tapped, control=None):
    if control:
        filename, old, new = CONTROLS[control]
        if path == filename:
            if data.count(old) != 1:
                raise ValueError('control source drift: ' + control)
            data = data.replace(old, new)
    if tapped and path == CATALOG['boundary']:
        if data.count(ANCHOR) != 1 or sha(TAP) != CATALOG['tap_sha256']:
            raise ValueError('native observation boundary/tap changed')
        data = data.replace(ANCHOR, ANCHOR + TAP)
    return data


def verify_source(sources, tapped, control=None):
    """Reverse exactly the recorded C edits, then compare every file to pins."""
    if set(sources) != set(CATALOG['files']):
        return 'native source file set differs from frozen catalog'
    if sha(TAP) != CATALOG['tap_sha256']:
        return 'tap differs from frozen catalog'
    if control is not None and control not in CONTROLS:
        return 'unknown native source control'
    for path, data in sources.items():
        if tapped and path == CATALOG['boundary']:
            if data.count(ANCHOR + TAP) != 1:
                return 'tap/boundary mismatch: ' + path
            data = data.replace(ANCHOR + TAP, ANCHOR)
        if control and path == CONTROLS[control][0]:
            _, old, new = CONTROLS[control]
            if data.count(new) != 1:
                return 'control mismatch: ' + path
            data = data.replace(new, old)
        if sha(data) != CATALOG['files'][path]:
            return 'source drift outside named observation/control edits: ' + path
    return None


def source_receipt(root, core, tapped, control=None):
    """Collector-owned source and artifact bytes, rechecked on bundle replay."""
    root = Path(root)
    if Path(core).resolve() != root.resolve() / 'rust/target/release/safedeps-core':
        raise ValueError('native artifact must belong to this observation archive')
    files = {str(p.relative_to(root)): p.read_bytes() for p in (root / 'rust').rglob('*')
             if p.is_file() and 'target' not in p.relative_to(root).parts}
    why = verify_source(files, tapped, control)
    if why:
        raise ValueError(why)
    return {'files': files, 'binary': Path(core).read_bytes(), 'tapped': tapped, 'control': control,
            'catalog_sha256': sha((HERE / 'native-catalog.json').read_bytes())}


def pack_receipt(receipt, blobs):
    packed = dict(receipt, files={p: blobs.put(data) for p, data in receipt['files'].items()},
                  binary=blobs.put(receipt['binary']))
    if 'builder' in receipt:
        packed['builder'] = blobs.put(receipt['builder'])
    return packed


def run_observed(run_hook, argv, data, env, cwd, timeout):
    # The descriptor is inherited only by this launch. Serialize descriptor
    # ownership even when the caller uses the CLI's two-worker collector.
    with FD_LOCK, tempfile.TemporaryFile() as sink:
        try:
            os.fstat(FD)
        except OSError:
            pass
        else:
            raise ValueError('native collector FD already in use')
        os.dup2(sink.fileno(), FD)
        try:
            result = run_hook(argv, data, env, cwd, timeout, pass_fds=(FD,))
        finally:
            os.close(FD)
        sink.seek(0)
        result['native_raw'] = sink.read()
        result['collector_pid'] = os.getpid()
        return result


def events(side, k):
    s = side.steps[k]
    admitted = side.doc.get('_evidence', {})
    if admitted.get('status') != 'accepted':
        return [], 'native events require admitted evidence'
    receipt = s.get('native')
    if admitted.get('collection_kind') == 'synthetic' and receipt is None:
        receipt = side.doc.get('native')  # Explicit historical fixture, never live authority.
    if not receipt:
        return [], 'native source/observation receipt absent'
    if receipt.get('catalog_sha256') != sha((HERE / 'native-catalog.json').read_bytes()):
        return [], 'native catalog changed; previous proof is invalid'
    sources = {p: side.blobs.get(d) for p, d in receipt['files'].items()}
    why = verify_source(sources, receipt['tapped'], receipt.get('control'))
    if why:
        return [], why
    # Force verification of the retained artifact bytes as well as source.
    side.blobs.get(receipt['binary'])
    if not receipt['tapped']:
        return [], 'plain binary: exact clock provenance unobserved'
    if 'native_raw' not in s:
        return [], 'native raw stream absent'
    raw = side.blobs.get(s['native_raw'])
    out = []
    roles = set(CATALOG['artifact_roles']) | set(CATALOG['internal_roles'])
    for ordinal, line in enumerate(raw.splitlines(keepends=True)):
        try:
            magic, pid, ppid, seq, role, sign, secs, nanos = line.decode('ascii').strip().split('\t')
            pid, ppid, seq, secs, nanos = map(int, (pid, ppid, seq, secs, nanos))
        except (ValueError, UnicodeError):
            return [], 'malformed native raw event'
        if (not line.endswith(b'\n') or magic != 'wall1' or role not in roles or seq != ordinal
                or sign not in ('before', 'after') or secs < 0 or not 0 <= nanos < 10**9):
            return [], 'missing/duplicate/out-of-order or invalid native event'
        # Inherited FD + exact launched process binds a start identity. A child
        # needs separate independently collected lifecycle evidence; no PID guess.
        if pid != s['pid'] or ppid != s.get('collector_pid'):
            return [], 'native child/start identity was not independently observed'
        event_id = '%s/%s/%s/%d/%s' % (side.doc.get('run_id'), side.doc.get('execution_id'), s['native_raw'], seq, role)
        out.append({'id': event_id, 'role': role, 'ordinal': seq, 'seconds': secs if sign == 'after' else 0,
                    'nanos': nanos, 'sign': sign})
    return out, None


def claim_result(side, claim, actual, source_role, ordinal=0, count=1):
    from .slots import clock_seconds, ok, unresolved, violation, token
    ev, why = events(side, claim.step)
    if why:
        return unresolved(why)
    selected = [e for e in ev if e['role'] == source_role]
    if len(selected) != count:
        return unresolved('%s expected %d independent events, observed %d' % (source_role, count, len(selected)))
    event = selected[ordinal]
    if clock_seconds(claim.fmt, actual) != event['seconds']:
        return violation('%s consumer %s differs from raw event %d (%s seconds)' %
                         (source_role, claim.key, event['ordinal'], event['seconds']))
    return ok(token(claim.role), [event['id']])


def snapshot_role(side, claim, actual):
    """One exclusive snapshot family for one independently named pre call.

    The fixture supplies command/cwd/call, the process supplies PID, and the
    before/after tree establishes one new family. More families are ambiguous.
    This does not prove arbitrary occurrences of the same string in file bodies.
    """
    from .slots import SNAP_ENTRY, unresolved
    k = claim.step
    hook = side.hook(k)
    if not hook or hook['hook'] != 'pre':
        return unresolved('snapshot birth is not a pre hook')
    families = {m.group(1) for rel in side.bounds[k + 1]
                if rel not in side.bounds[k] and (m := SNAP_ENTRY.match(rel))}
    if len(families) != 1:
        return unresolved('snapshot role requires exactly one newly observed family')
    return claim_result(side, claim, actual, 'PreSnapshot')


def log_role(side, claim, actual, claims):
    """Single append consumers whose subject is independently known.

    Several attempts, partial writes, multiple recovered entries or competing
    header roles are not assigned by timestamps or candidate line order.
    """
    from .slots import unresolved
    k = claim.step
    group = [c for c in claims.values() if c.step == k and c.chain == claim.chain]
    if len(group) != 1:
        return unresolved('repeated log append consumers need independent operation identities')
    ev, why = events(side, k)
    if why:
        return unresolved(why)
    if claim.chain == 'state/advisory.log@step%d' % k:
        header_roles = {'AdvisoryHeader', 'ProviderHeader', 'AdvisoryRotationHeader'}
        headers = [e for e in ev if e['role'] in header_roles]
        # Only the single ordinary pre diagnostic is currently bound. Provider
        # and rotation work can interleave and needs further operation evidence.
        if len(headers) == 1 and headers[0]['role'] == 'AdvisoryHeader' and side.hook(k)['hook'] == 'pre':
            return claim_result(side, claim, actual, 'AdvisoryHeader')
    if claim.chain == 'state/reorg.log@step%d' % k:
        seed = [(p, e) for p, e in side.bounds[k].items()
                if p.startswith('state/rollback-journal/') and p.endswith('.json') and e.get('kind') == 'file']
        if len(seed) == 1:
            path, entry = seed[0]
            incident = path.replace('/rollback-journal/', '/rollback-incidents/', 1)
            after = side.bounds[k + 1].get(incident, {})
            if path not in side.bounds[k + 1] and after.get('blob') == entry.get('blob'):
                return claim_result(side, claim, actual, 'JournalRecoveryHeader')
    return unresolved('no frozen independent append/consumer binding for ' + claim.chain)


def gaps(side, occurrences):
    """Validate streams even if a broken consumer leaves no timestamp slot."""
    if side.doc.get('_evidence', {}).get('status') != 'accepted':
        return ['native evidence was not admitted']
    problems = []
    for k, step in enumerate(side.steps):
        if step.get('impl') != 'core':
            continue
        receipt = step.get('native', side.doc.get('native', {}))
        if not receipt.get('tapped'):
            continue
        ev, why = events(side, k)
        if why:
            problems.append(why)
            continue
        witnessed = {w for o in occurrences for w in o.result.witness}
        for e in ev:
            witness = e['id']
            if e['role'] in CATALOG['artifact_roles'] and witness not in witnessed:
                problems.append('unbound native event %s; failed/removed/repeated sinks are not inferred' % witness)
    return problems
