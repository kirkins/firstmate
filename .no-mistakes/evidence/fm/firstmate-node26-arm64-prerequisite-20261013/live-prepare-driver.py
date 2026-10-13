from pathlib import Path
import os, subprocess
root=Path.cwd(); lab=root/'.phase-test/live'; evidence=Path('/home/kirkins/.no-mistakes/evidence/01M4SY6F33MYQ2TY37P26GRS8K')
for d in ['clientbin','sandboxbin','prefix','tmp','home','fixture']:(lab/d).mkdir(parents=True,exist_ok=True)
def script(path,content):
 path.write_text('#!/usr/bin/env bash\nset -eu\n'+content);path.chmod(0o755)
script(lab/'clientbin/kubectl',"printf disposable-lab-value | base64\n")
script(lab/'clientbin/sbx',r'''
if [ "$1" = login ]; then cat >/dev/null; exit 0; fi
[ "$1 $2" = '--cloud exec' ] || exit 2
shift 4
eval "set -- $*"
[ "$#" -eq 3 ] && [ "$1 $2" = 'bash -lc' ] || exit 2
exec bwrap --ro-bind / / --tmpfs /home --dev /dev --proc /proc \
 --bind "$PHASE_LAB/tmp" /tmp --bind "$PHASE_LAB/prefix" /usr/local \
 --bind "$PHASE_LAB" /mnt --ro-bind /bin/false /usr/bin/node \
 --setenv HOME /mnt/home --setenv GIT_CONFIG_GLOBAL /dev/null --setenv GIT_CONFIG_NOSYSTEM 1 \
 --setenv PATH /usr/local/bin:/mnt/sandboxbin:/usr/bin:/bin --chdir /mnt \
 bash --noprofile --norc -c "$3"
''')
script(lab/'sandboxbin/sudo','exec "$@"\n')
script(lab/'sandboxbin/apt-get',r'''
printf 'preprovisioned package request: %s\n' "$*" >&2
case "$*" in
 'update -qq'|'install -y -qq xz-utils tmux libatomic1 ruby gcc time') exit 0;;
 *) exit 2;;
esac
''')
script(lab/'sandboxbin/curl',r'''
printf 'real curl: %s\n' "$*" >&2
exec /usr/bin/curl "$@"
''')
env=dict(os.environ,PHASE_LAB=str(lab),FM_HOME=str(lab/'home'),FM_REMOTE_HANDS='1',FM_REMOTE_HANDS_SECRET='lab/disposable',PATH=str(lab/'clientbin')+':'+os.environ['PATH'],GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR']:env.pop(key,None)
subprocess.run(['git','init','-q',str(lab/'fixture')],env=env,check=True)
(lab/'fixture/check.js').write_text("if (process.versions.node.split('.')[0] !== '26') process.exit(1); console.log('required Node 26:',process.version);\n")
subprocess.run(['git','-C',str(lab/'fixture'),'add','.'],env=env,check=True)
subprocess.run(['git','-C',str(lab/'fixture'),'-c','user.name=Lab','-c','user.email=lab@example.invalid','-c','commit.gpgsign=false','commit','--allow-empty','-qm','fixture'],env=env,check=True)
cmd=['bash','bin/fm-remote-hands.sh','prepare','--name','fm-lab-node26','--repo','file:///mnt/fixture','--dest','/mnt/clone']
result=subprocess.run(cmd,env=env,text=True,capture_output=True,timeout=120)
log='Live local filesystem sandbox; real uname, Node distribution, curl, sha256sum, tar and git.\nCloud transport and credentials replaced with local adapters; package requests preprovisioned.\nCommand: '+ ' '.join(cmd)+'\nexit: '+str(result.returncode)+'\n'+result.stdout+result.stderr
(evidence/'live-prepare.log').write_text(log);print(log)
