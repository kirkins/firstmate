import os,pathlib,subprocess,json,shutil,re,time,sys,shlex
root=pathlib.Path.cwd(); temp=root/'.validation-temp/canonical'
evidence=pathlib.Path('/home/kirkins/.no-mistakes/evidence/01M4V7WVYY8990PVF2KHGYMYVG')
owner='/home/kirkins/Documents/firstmate/bin/fm-heavy-slot.sh'
if temp.exists():shutil.rmtree(temp)
repo=temp/'repo';config=temp/'config'; repo.mkdir(parents=True,exist_ok=True)
for name in ['bin','bin/backends','tests','.github/workflows']:(repo/name).mkdir(parents=True,exist_ok=True)
for name in ['fm-lint.sh','fm-lint-resource-lib.sh','fm-timeout-lib.sh','fm-lint-workflows.sh']:
    shutil.copy2(root/'bin'/name,repo/'bin'/name)
(repo/'bin/backends/proof.sh').write_text('#!/usr/bin/env bash\nexit 0\n')
(repo/'.github/workflows/proof.yml').write_text('name: proof\non: push\njobs:\n  proof:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo harmless\n')
(config/'firstmate').mkdir(parents=True,exist_ok=True)
binding=config/'firstmate/lint-resource-binding.json'
binding.write_text(json.dumps(dict(home='/home/kirkins/Documents/firstmate',jobs=1,estimate_mib=1024)))
binding.chmod(0o600)
env=os.environ.copy()
for key in ['FM_LINT_RESOURCE_TASK','XDG_STATE_HOME','GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE']:env.pop(key,None)
env.update(XDG_CONFIG_HOME=str(config),TMPDIR=str(root/'.validation-temp/tmp'),FM_LINT_JOBS='1',FM_LINT_REQUIRE_BOUNDS='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GITHUB_ACTIONS='',CI='')
for args in [['init','-q','-b','main'],['add','.'],['-c','user.name=Disposable validation','-c','user.email=validation@example.invalid','commit','-qm','Disposable fixture baseline'],['checkout','-qb','live-proof']]:
    subprocess.run(['git',*args],cwd=repo,env=env,check=True,capture_output=True)
(repo/'tests/clean-a.sh').write_text('#!/usr/bin/env bash\nprintf "clean a\\n"\n')
(repo/'tests/clean-b.sh').write_text('#!/usr/bin/env bash\nprintf "clean b\\n"\n')
subprocess.run(['git','add','tests'],cwd=repo,env=env,check=True)
with (evidence/'current-canonical-plain.log').open('a') as log:
    def emit(s):print(s,flush=True);log.write(s+'\n');log.flush()
    emit('Source head: '+subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip())
    emit('Disposable opt-in: '+binding.read_text())
    emit('No outer slot: each plain entrypoint self-acquires the canonical owner.')
    for label,expected in [('success',0),('findings',1)]:
        if label=='findings':(repo/'tests/clean-b.sh').write_text('#!/usr/bin/env bash\nvalue=$1\nprintf "%s\\n" $value\n')
        env['FM_LINT_TELEMETRY']=str(evidence/f'current-canonical-{label}.tsv')
        emit('$ (cd disposable-repo; FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=1 bin/fm-lint.sh) ['+label+']')
        telemetry_path=pathlib.Path(env['FM_LINT_TELEMETRY'])
        prior_mtime=telemetry_path.stat().st_mtime_ns if telemetry_path.exists() else None
        start=time.monotonic()
        process=subprocess.Popen(['bin/fm-lint.sh'],cwd=repo,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        output='';group=None; kernel_cap=None;held=None
        for line in process.stdout:
            output+=line;emit(line.rstrip('\n'))
            match=re.search(r'^fm-lint.sh: bound .*cgroup=(\S+) helper=',line)
            if match:
                group=match[1]
                kernel_cap=pathlib.Path('/sys/fs/cgroup'+group+'/memory.max').read_text().strip()
                held=subprocess.check_output([owner,'status'],env=env,text=True).strip()
                emit('Independent kernel memory.max='+kernel_cap)
                emit('Independent canonical ownership='+held)
        rc=process.wait()
        emit(f'entrypoint exit={rc}; elapsed_seconds={time.monotonic()-start:.3f}')
        status=subprocess.check_output([owner,'status'],env=env,text=True).strip();emit('canonical slot after entrypoint='+status)
        if rc==6:
            emit('CONTENTION: no analysis; existing holder preserved. Waiting is required before re-driving.')
            assert held is None and (telemetry_path.stat().st_mtime_ns if telemetry_path.exists() else None)==prior_mtime
            sys.exit(6)
        events=pathlib.Path('/sys/fs/cgroup'+group+'/cgroup.events') if group else None
        emit('owned scope after entrypoint='+(events.read_text().strip() if events and events.exists() else 'removed'))
        telemetry=pathlib.Path(env['FM_LINT_TELEMETRY']).read_text();emit('Generated telemetry:\n'+telemetry)
        assert rc==expected,(label,rc,expected)
        assert kernel_cap=='1073741824',kernel_cap
        assert held and 'held task=lint-' in held and 'estimate=1024MB' in held,held
        assert 'jobs\t1\n' in telemetry and 'root_count\t2\n' in telemetry,telemetry
        assert status=='free',status
        assert not events.exists() or 'populated 0' in events.read_text()
        if label=='findings':assert 'SC2086' in output
    emit('Both current-source plain invocations satisfied their observable contracts.')
