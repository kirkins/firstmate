import os, pathlib, subprocess, shlex, sys
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/kirkins/.no-mistakes/evidence/01M4V7WVYY8990PVF2KHGYMYVG')
owner='/home/kirkins/Documents/firstmate/bin/fm-heavy-slot.sh'
task='firstmate-lint-resource-binding-20261013'
env=os.environ.copy()
env.update(FM_LINT_JOBS='1',FM_LIVE_LINT_RESOURCE='1',TMPDIR=str(root/'.validation-temp/tmp'),LOCAL_EVIDENCE=str(evidence))
with (evidence/'current-missing-time-transcript.log').open('w') as log:
    def emit(s):
        print(s,flush=True); log.write(s+'\n'); log.flush()
    acquire=subprocess.run([owner,'acquire',task,'--estimate','1024'],text=True,capture_output=True)
    emit('$ '+shlex.join([owner,'acquire',task,'--estimate','1024']))
    emit(acquire.stdout+acquire.stderr)
    if acquire.returncode:
        emit('acquire exit='+str(acquire.returncode));sys.exit(acquire.returncode)
    try:
        wrappers=[line.strip().removesuffix('<command>').strip() for line in acquire.stdout.splitlines() if line.startswith('  systemd-run ') and line.endswith('<command>')]
        if len(wrappers)!=1: raise RuntimeError('canonical owner did not print one supported wrapper')
        wrapper=shlex.split(wrappers[0])
        command=wrapper+['bash','bin/fm-test-run.sh','--jobs','1','tests/fm-local-missing-time.test.sh','--json',str(evidence/'current-missing-time-timing.json')]
        emit('$ FM_LINT_JOBS=1 FM_LIVE_LINT_RESOURCE=1 '+shlex.join(command))
        process=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        for line in process.stdout:
            emit(line.rstrip('\n'))
        rc=process.wait();emit('focused runner exit='+str(rc))
    finally:
        release=subprocess.run([owner,'release',task],text=True,capture_output=True)
        emit('$ '+shlex.join([owner,'release',task]));emit(release.stdout+release.stderr)
        emit('release exit='+str(release.returncode))
        status=subprocess.run([owner,'status'],text=True,capture_output=True)
        emit('canonical slot after release: '+status.stdout.strip())
    sys.exit(rc)
