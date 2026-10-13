import os,pathlib,subprocess,hashlib,json
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/kirkins/.no-mistakes/evidence/01M4T32YT3CJB011SDSCDP8QGR')
lab=root/'.test-checksum-tmp'
case=lab/'assertion-failure'
(case/'host-tmp').mkdir(parents=True, exist_ok=True)
(case/'fixture-tmp').mkdir(exist_ok=True)
(case/'home').mkdir(exist_ok=True)
sentinel=case/'host-tmp/fm-node.tar.xz'
sentinel.write_bytes(b'pre-existing archive must survive regression failure\n')
before=hashlib.sha256(sentinel.read_bytes()).hexdigest()
cmd=['bwrap','--ro-bind','/usr','/usr','--symlink','usr/bin','/bin','--symlink','usr/lib','/lib','--proc','/proc','--dev','/dev',
     '--ro-bind',str(root),str(root),'--bind',str(case/'host-tmp'),'/tmp',
     '--bind',str(case/'fixture-tmp'),str(case/'fixture-tmp'),'--bind',str(case/'home'),'/home/lab',
     '--ro-bind',str(lab/'runtime/base-bin/fm-remote-hands.sh'),str(root/'bin/fm-remote-hands.sh'),
     '--setenv','HOME','/home/lab','--setenv','TMPDIR',str(case/'fixture-tmp'),
     '--setenv','PATH','/usr/bin:/usr/bin/core_perl','--setenv','FM_LINT_JOBS','1',
     '--unshare-net','--die-with-parent','--chdir',str(root),'--','/usr/bin/bash','tests/fm-remote-hands.test.sh']
p=subprocess.run(cmd,text=True,capture_output=True)
after=hashlib.sha256(sentinel.read_bytes()).hexdigest()
remaining=[str(p.relative_to(case/'fixture-tmp')) for p in (case/'fixture-tmp').iterdir()]
record={'exit':p.returncode,'sentinel_before':before,'sentinel_after':after,'sentinel_unchanged':before==after,'fixture_temp_remaining':remaining}
(evidence/'assertion-failure-isolation.log').write_text('Current regression test against pre-fix production executable in private filesystem; /tmp sentinel belongs to this disposable namespace.\n'+json.dumps(record,indent=2)+'\nSTDOUT:\n'+p.stdout+'STDERR:\n'+p.stderr)
print(json.dumps(record,indent=2))
assert p.returncode!=0 and 'missing checksum must fail prepare' in p.stderr,p.stderr
assert before==after and not remaining,record

profile=case/'login-profile'
profile.write_text('export PATH=/usr/bin:/usr/bin/core_perl:$PATH\n')
# Use actual bash -lc initialization with system commands prepended. All writes
# remain in the disposable namespace and external network access is absent.
current=cmd[:]
i=current.index('--ro-bind',current.index('--ro-bind')+1)
# Delete only the pre-fix product file overlay.
for j in range(len(current)-2):
    if current[j:j+3]==['--ro-bind',str(lab/'runtime/base-bin/fm-remote-hands.sh'),str(root/'bin/fm-remote-hands.sh')]:
        del current[j:j+3]
        break
current[1:1]=['--dir','/etc','--ro-bind',str(profile),'/etc/profile']
p=subprocess.run(current,text=True,capture_output=True)
record={'exit':p.returncode,'login_profile':'prepends /usr/bin ahead of fixture PATH','sentinel_unchanged':hashlib.sha256(sentinel.read_bytes()).hexdigest()==before,'fixture_temp_remaining':list((case/'fixture-tmp').iterdir())}
(evidence/'login-path-isolation.log').write_text(json.dumps(record,indent=2)+'\nSTDOUT:\n'+p.stdout+'STDERR:\n'+p.stderr)
print(json.dumps(record,indent=2))
assert p.returncode==0 and record['sentinel_unchanged'] and not record['fixture_temp_remaining'],p.stderr
