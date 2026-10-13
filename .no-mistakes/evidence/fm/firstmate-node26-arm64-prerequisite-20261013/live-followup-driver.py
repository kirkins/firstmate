from pathlib import Path
import subprocess, shutil
exec(Path('.phase-test/live-prepare.py').read_text().split('result=subprocess.run(cmd')[0])
def capture(label,command):
 r=subprocess.run(command,env=env,text=True,capture_output=True,timeout=60)
 text=f'Command: {command!r}\nexit: {r.returncode}\n'+r.stdout+r.stderr
 (evidence/(label+'.log')).write_text(text);print(label+'\n'+text);return r
r=capture('live-node26-fixture',['sbx','--cloud','exec','fm-lab-node26','--','bash','-lc',"'node /mnt/clone/check.js; uname -m'"])
assert r.returncode==0 and 'required Node 26: v26.' in r.stdout and 'aarch64' in r.stdout
r=capture('live-matching-node26',cmd)
assert r.returncode==0 and 'already matches local major 26' in r.stderr and 'real curl:' not in r.stderr
# Restore only disposable state to the original no-Node starting condition.
shutil.rmtree(lab/'prefix');(lab/'prefix').mkdir()
shutil.rmtree(lab/'clone')
mutant=root/'bin/.phase-live-mutant.sh'
original=(root/'bin/fm-remote-hands.sh').read_text()
try:
 mutant.write_text(original.replace('case "$arch" in\n  aarch64) arch=arm64 ;;\nesac\n','',1));mutant.chmod(0o755)
 mutantcmd=cmd.copy();mutantcmd[1]='bin/.phase-live-mutant.sh'
 r=capture('live-reverted-mapping',mutantcmd)
 assert r.returncode==1 and 'node tarball not found under https://nodejs.org/dist/latest-v26.x' in r.stderr
 assert 'real curl: -fsSL -o' not in r.stderr
finally:
 mutant.unlink(missing_ok=True)
