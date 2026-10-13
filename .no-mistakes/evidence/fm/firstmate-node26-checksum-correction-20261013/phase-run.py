import os, subprocess, pathlib, shutil, resource, mmap, errno
root=pathlib.Path.cwd()
ev=pathlib.Path('/home/kirkins/.no-mistakes/evidence/01M4T32YT3CJB011SDSCDP8QGR')
lab=root/'.test-checksum-phase'
env=os.environ | {'XDG_STATE_HOME':str(lab/'followup/slot-state'),'FM_STATE_OVERRIDE':str(lab/'followup/slot-runtime'),'FM_HOME':str(lab/'home'),'FM_LINT_JOBS':'1'}
slot=[str(root/'bin/fm-heavy-slot.sh')]
log=[]
def run(args, **kw):
    p=subprocess.run(args,env=env,text=True,capture_output=True,**kw)
    log.append('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
    print(p.stdout+p.stderr,flush=True)
    return p
held=False
try:
    acquired=run(slot+['acquire','checksum-followup','--estimate','4096'])
    assert acquired.returncode==0
    held=True
    for driver in ['phase-drive-checksum.py','phase-drive-followup.py']:
        proc=run(['prlimit','--as=4294967296:4294967296','--','python3',str(ev/driver)])
        assert proc.returncode==0, driver
    assert run(['node','--version']).stdout.strip()=='v26.10.0'
finally:
    if held:
        assert run(slot+['release','checksum-followup']).returncode==0
        assert run(slot+['status']).stdout.strip()=='free'
    (ev/'phase-execution.log').write_text('Sequential checks; FM_LINT_JOBS=1; 4GiB hard/soft process address-space cap; worktree-local isolated heavy slot.\n'+''.join(log))
    shutil.rmtree(lab)
