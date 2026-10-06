"""The core-hook collector's build, launch and completed-run boundary.

Trust: the frozen builder/collector and host; the consumer selects a completed
manifest digest OUTSIDE the bundle. This is not attestation against a hostile
compiler, host or simultaneous executable replacement. Paths are recorded facts,
never replay lookup locations. Synthetic fixtures need explicit opt-in and make
no live provenance claim. Historical unsealed runs cannot acquire live receipts.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import uuid

BUILD = 'core-hook-build/1'
MANIFEST = 'core-hook-evidence/1'
LAUNCH = 'core-hook-launch/1'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(doc):
    return (json.dumps(doc, sort_keys=True, ensure_ascii=True, separators=(',', ':')) + '\n').encode()


def digest(doc):
    return sha(encoded(doc))


def strict_load(data):
    def pairs(items):
        out = {}
        for key, value in items:
            if key in out:
                raise ValueError('duplicate evidence metadata key: ' + key)
            out[key] = value
        return out
    def constant(value):
        raise ValueError('non-JSON metadata constant: ' + value)
    return json.loads(data, object_pairs_hook=pairs, parse_constant=constant)


def publish(path, data):
    """Single writer, atomic publication, never overwrite a completed file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.part')
    with tmp.open('xb') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    # link fails if destination already exists; rename alone would replace it.
    os.link(tmp, path)
    tmp.unlink()
    return sha(data)


def sources():
    here = Path(__file__).resolve().parent
    paths = list(here.glob('*.py')) + list(here.glob('*.json')) + list(here.glob('*.rs'))
    paths += [here.parent / n for n in ('core-hook-differential.py', 'core-hook-native.py')]
    return {str(p.relative_to(here.parent)): sha(p.read_bytes()) for p in sorted(paths)}


def require(value, kind, label):
    if type(value) is not kind:
        raise ValueError('invalid ' + label + ' type')
    return value


def hex_digest(value, label):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value):
        raise ValueError('invalid ' + label + ' digest')
    return value


def builder_relation(receipt, blobs):
    """The builder's exact source -> artifact relation, not set membership."""
    from . import native
    require(receipt, dict, 'native receipt')
    tapped = require(receipt['tapped'], bool, 'tapped')
    files = require(receipt['files'], dict, 'source files')
    raw_sources = {p: blobs.get(hex_digest(h, 'source')) for p, h in files.items()}
    why = native.verify_source(raw_sources, tapped, receipt.get('control'))
    if why:
        raise ValueError(why)
    if receipt['catalog_sha256'] != sha((native.HERE / 'native-catalog.json').read_bytes()):
        raise ValueError('native catalog mismatch')
    build_bytes = blobs.get(hex_digest(receipt['builder'], 'builder'))
    build = strict_load(build_bytes)
    require(build, dict, 'builder')
    if build.get('format') != BUILD:
        raise ValueError('builder receipt format mismatch')
    expected = {'source': native.CATALOG['source'], 'files': files, 'binary_sha256': receipt['binary'],
                'tapped': tapped, 'control': receipt.get('control'),
                'catalog_sha256': receipt['catalog_sha256'], 'tap_sha256': native.CATALOG['tap_sha256']}
    for key, value in expected.items():
        if build.get(key) != value:
            raise ValueError('builder relation mismatch: ' + key)
    blobs.get(hex_digest(receipt['binary'], 'binary'))
    if type(build.get('build_rc')) is not int or build['build_rc'] != 0:
        raise ValueError('builder did not complete successfully')
    if build.get('stamp') != {'rc': 0, 'stdout': 'ok\n', 'stderr': ''}:
        raise ValueError('builder stamp not successful')
    for key, typ in (('argv', list), ('env', dict), ('toolchain', dict), ('target', str), ('build_log_sha256', str)):
        require(build.get(key), typ, 'builder ' + key)
    if not build['argv'] or not build['target'] or set(build['toolchain']) != {'cargo', 'rustc'}:
        raise ValueError('incomplete builder invocation')
    for tool in build['toolchain'].values():
        require(tool, dict, 'toolchain entry')
        hex_digest(tool['sha256'], 'toolchain executable')
        require(tool['version'], str, 'toolchain version')
        require(tool['path'], str, 'toolchain path')
    hex_digest(build['build_log_sha256'], 'build log')
    return build


def accepted_build(root, core, receipt_path, expected):
    """Reuse an already selected builder record; do not issue a new receipt."""
    from . import native, observe
    raw = Path(receipt_path).read_bytes()
    if sha(raw) != hex_digest(expected, 'expected builder'):
        raise ValueError('expected builder digest mismatch')
    build = strict_load(raw)
    receipt = native.source_receipt(root, core, build['tapped'], build.get('control'))
    receipt['builder'] = raw
    blobs = observe.Blobs()
    builder_relation(native.pack_receipt(receipt, blobs), blobs)
    return receipt


def executable(argv, env, cwd):
    path = argv[0]
    if '/' not in path:
        path = shutil.which(path, path=env.get('PATH'))
    elif not os.path.isabs(path):
        path = os.path.join(cwd, path)
    if not path:
        raise ValueError('launch executable not found')
    return {'path': os.path.abspath(path), 'sha256': sha(Path(path).read_bytes())}


def before_launch(hook, env, cwd):
    before = executable(hook['argv'], env, cwd)
    receipt = hook.get('native_receipt')
    if receipt:
        from . import native
        current = native.source_receipt(hook['roots'][-1], hook['argv'][0], receipt['tapped'], receipt.get('control'))
        if current['files'] != receipt['files'] or current['binary'] != receipt['binary']:
            raise ValueError('archive changed between accepted build and launch')
        if before['sha256'] != sha(receipt['binary']):
            raise ValueError('launch executable differs from accepted builder artifact')
    return before


def after_launch(hook, env, cwd, before):
    after = before_launch(hook, env, cwd)
    if before != after:
        raise ValueError('executable/source changed during launch')
    return after


def execution_record(side, k):
    s = side['steps'][k]
    return {'run': side['run_id'], 'execution': side['execution_id'], 'step': k,
            'launch': s['launch'], 'step_sha256': digest(s),
            'before_sha256': digest(side['boundaries'][k]),
            'after_sha256': digest(side['boundaries'][k + 1])}


class Collection:
    """One prospective run, one writer. Not a sealer for saved bundles."""
    def __init__(self, out):
        self.out = Path(out)
        self.out.mkdir(parents=True, exist_ok=True)
        publish(self.out / 'collection.started.json', encoded({'format': MANIFEST, 'run': (run := str(uuid.uuid4()))}))
        self.run = run
        self.collector_sources = sources()
        self.executions = {}
        self.bundles = []
        self.closed = False

    def side_finished(self, side):
        if self.closed or side['run_id'] != self.run or side['execution_id'] in self.executions:
            raise ValueError('duplicate/foreign/completed collection execution')
        self.executions[side['execution_id']] = [execution_record(side, k) for k, s in enumerate(side['steps']) if s['kind'] == 'hook']

    def bundle_written(self, path, document):
        if self.closed or document.get('meta', {}).get('collection_kind') != 'live':
            raise ValueError('only prospective live collections can publish live evidence')
        executions = {}
        for name, side in document['sides'].items():
            if side.get('run_id') != self.run or side.get('execution_id') not in self.executions:
                raise ValueError('bundle has no prospective collection execution')
            records = [execution_record(side, k) for k, s in enumerate(side['steps']) if s['kind'] == 'hook']
            if records != self.executions[side['execution_id']]:
                raise ValueError('bundle changed after collection')
            executions[name] = records
        raw = Path(path).read_bytes()
        self.bundles.append({'path': Path(path).name, 'sha256': sha(raw),
                             'fixture_sha256': digest(document['case']), 'executions': executions})

    def finish(self):
        if self.closed or not self.bundles:
            raise ValueError('empty/already completed collection')
        if sources() != self.collector_sources:
            raise ValueError('collector source changed during collection')
        for item in self.bundles:
            if sha((self.out / item['path']).read_bytes()) != item['sha256']:
                raise ValueError('bundle changed before completion')
        doc = {'format': MANIFEST, 'complete': True, 'collection_kind': 'live', 'run': self.run,
               'collector_sources': self.collector_sources, 'bundles': self.bundles}
        path = self.out / 'evidence.manifest.json'
        pin = publish(path, encoded(doc))  # Last required file; no report/verdict is authority.
        self.closed = True
        return path, pin


def state(status, reason, kind=None, anchor=None):
    return {'status': status, 'reason': reason, 'collection_kind': kind, 'anchor': anchor}


def admit(doc, bundle_sha, manifest_path=None, expected=None, synthetic=False):
    """Return an evidence state before any consumer values are normalized."""
    kind = doc.get('meta', {}).get('collection_kind')
    try:
        if synthetic:
            if kind != 'synthetic':
                raise ValueError('synthetic replay requires a declared synthetic fixture')
            return state('accepted', 'explicit synthetic fixture; no live provenance', kind)
        if kind == 'synthetic':
            return state('unresolved', 'synthetic fixture needs explicit --synthetic replay', kind)
        if not manifest_path or not expected:
            return state('unresolved', 'missing independently selected completed-manifest digest', kind)
        raw = Path(manifest_path).read_bytes()
        if sha(raw) != hex_digest(expected, 'expected manifest'):
            raise ValueError('completed manifest differs from independently selected digest')
        manifest = strict_load(raw)
        require(manifest, dict, 'manifest')
        if manifest.get('format') != MANIFEST:
            raise ValueError('unknown evidence manifest format')
        if manifest.get('complete') is not True:
            return state('unresolved', 'collection manifest is incomplete', kind, expected)
        if kind != 'live' or manifest.get('collection_kind') != 'live':
            return state('unresolved', 'bundle has no prospective live collection', kind, expected)
        if manifest.get('collector_sources') != sources():
            raise ValueError('collector/comparator version differs from completed run')
        bundles = require(manifest['bundles'], list, 'manifest bundles')
        selected = [b for b in bundles if b['sha256'] == bundle_sha]
        if len(selected) != 1:
            raise ValueError('bundle absent/duplicated in selected completed manifest')
        item = selected[0]
        if item['fixture_sha256'] != digest(doc['case']):
            raise ValueError('fixture relation differs')
        for name, side in doc['sides'].items():
            side['_evidence'] = state('accepted', 'completed manifest selected', kind, expected)
            if side.get('run_id') != manifest['run']:
                raise ValueError('run relation differs')
            records = item['executions'][name]
            actual = []
            for k, step in enumerate(side['steps']):
                if step['kind'] != 'hook':
                    continue
                launch = step.get('launch')
                if launch is None:
                    return state('unresolved', 'hook has no prospective launch receipt', kind, expected)
                require(launch, dict, 'launch')
                if launch.get('format') != LAUNCH:
                    raise ValueError('launch format mismatch')
                relation = {'run': side['run_id'], 'execution': side['execution_id'], 'step': k,
                            'argv': step['argv'], 'stdin': step['stdin'], 'pid': step['pid'],
                            'collector_pid': step.get('collector_pid'), 'env': step['env'], 'cwd': step['cwd']}
                for key, value in relation.items():
                    if launch.get(key) != value:
                        raise ValueError('launch relation mismatch: ' + key)
                if launch['executable_before'] != launch['executable_after']:
                    raise ValueError('launch executable changed')
                if step['impl'] == 'core':
                    receipt = step.get('native')
                    if not receipt or not receipt.get('builder'):
                        return state('unresolved', 'native launch has no selected builder receipt', kind, expected)
                    builder_relation(receipt, side['blobs'])
                    if launch['builder'] != receipt['builder'] or launch['executable_before']['sha256'] != receipt['binary']:
                        raise ValueError('launched artifact differs from this step builder')
                    expected_fd = 198 if receipt['tapped'] else None
                    if launch['native_fd'] != expected_fd or (expected_fd and 'native_raw' not in step):
                        raise ValueError('launch descriptor/stream relation mismatch')
                actual.append(execution_record(side, k))
            if actual != records:
                raise ValueError('run/side/step stream or boundary relation mismatch')
        return state('accepted', 'completed manifest selected', kind, expected)
    except FileNotFoundError:
        return state('unresolved', 'selected evidence manifest is missing', kind, expected)
    except (ValueError, KeyError, TypeError, IndexError, OSError) as err:
        return state('invalid', str(err), kind, expected)


def attach(doc, admission):
    doc['_evidence'] = admission
    for side in doc['sides'].values():
        side['_evidence'] = admission
    return doc
