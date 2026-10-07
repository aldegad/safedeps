"""Obtain a monitored list from the real Bash pre hook, without an install."""
import json
import os
import subprocess


def project_bytes(project):
    return {str(p.relative_to(project)):['link',os.readlink(p)] if p.is_symlink() else ['file',p.read_bytes().hex()]
            for p in project.rglob('*') if p.is_symlink() or p.is_file()}


def pre_list(root,seed):
    project=seed/'project';project.mkdir(parents=True)
    (project/'package.json').write_text('{"name":"fixture","version":"1.0.0"}\n')
    (project/'package-lock.json').write_text('{"lockfileVersion":3,"packages":{}}\n')
    (seed/'user-home').mkdir()
    home=seed/'state'
    payload=dict(tool_name='Bash',tool_input=dict(command='npm install'),cwd=str(project),tool_use_id='normal-pre-list')
    env={k:v for k,v in os.environ.items() if not k.startswith('SAFEDEPS_')}
    env.update(SAFEDEPS_HOME=str(home),HOME=str(seed/'user-home'),NPM_CONFIG_USERCONFIG='/dev/null',LC_ALL='C')
    before=project_bytes(project)
    pre=subprocess.run([str(root/'scripts/safedeps-hook-entry.sh'),'pre'],input=json.dumps(payload).encode(),
                       cwd=project,env=env,capture_output=True,timeout=30)
    pending=home/'pending/id-normal-pre-list.json'
    if pre.returncode or not pending.is_file():raise RuntimeError('normal pre did not produce its record: '+repr((pre.returncode,pre.stdout,pre.stderr)))
    sid=json.loads(pending.read_text())['snapshot_id']
    listing=(home/'snapshots'/(sid+'_monitored_files.list')).read_text()
    after=project_bytes(project)
    if before!=after:raise RuntimeError('the pre fixture changed project bytes')
    return dict(rc=pre.returncode,stdout=pre.stdout.decode(),stderr=pre.stderr.decode(),
                list=listing,project_before=before,project_after=after)
