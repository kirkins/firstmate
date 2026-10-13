import os, pathlib, subprocess, shutil, hashlib, json
root=pathlib.Path.cwd(); lab=root/'.checksum-lab'; evidence=pathlib.Path('/home/kirkins/.no-mistakes/evidence/01M4V016HPH5A3J4VTRRX6MZKS')
source=(root/'tests/fm-remote-hands.test.sh').read_text().split('\ntest_help_and_usage_plumbing\n')[0]
source=source.replace('. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"', '. "'+str(root/'tests/lib.sh')+'"')
append=r'''
eval "$(declare -f hands | sed '1s/^hands/base_hands/')"
hands() {
  base_hands "$@"
  if [[ "$*" == *FM_FAKE_CHECKSUM_MODE=* ]]; then
    printf 'prepare invocation: %s\nexit=%s\nstdout:\n%s\nstderr:\n%s\n' "$*" "$HANDS_STATUS" "$HANDS_STDOUT" "$HANDS_STDERR"
    printf 'archive private=%s extraction=%s\n' "$(test -f "$TMP_ROOT/download/fm-node.tar.xz" && echo yes || echo no)" "$(test -f "$TMP_ROOT/extracted" && echo reached || echo absent)"
  fi
}
printf 'SHA backend: sha256sum=%s shasum=%s\n' "$(command -v sha256sum || true)" "$(command -v shasum || true)"
if [[ ${CHECKSUM_OLD:-0} == 1 ]]; then HANDS="$CHECKSUM_OLD_SCRIPT"; fi
test_fake_exec_restores_fixture_path_after_login
test_prepare_verifies_downloaded_archive_before_extraction
'''
(lab/'focused.sh').write_text(source+append)
oldbin=lab/'old-bin'; oldbin.mkdir(exist_ok=True)
(oldbin/'fm-remote-hands.sh').write_bytes(subprocess.check_output(['git','show','855c9ebfb61b5f7466b45d411f004f73cda7b868:bin/fm-remote-hands.sh']))
(oldbin/'fm-remote-hands.sh').chmod(0o755)
if not (oldbin/'fm-env-lib.sh').exists(): (oldbin/'fm-env-lib.sh').symlink_to(root/'bin/fm-env-lib.sh')
minimal=lab/'portable-bin'; minimal.mkdir(exist_ok=True)
for tool in ['bash','sed','tr','cut','grep','head','awk','cat','mv','mktemp','rm','mkdir','date','sleep','timeout','dirname','basename','base64','cp','chmod','ln','env','ps','readlink','stat','shasum','uname','id','perl','od']:
    path=shutil.which(tool)
    if path and not (minimal/tool).exists(): (minimal/tool).symlink_to(path)
login=lab/'reordered-bin'; login.mkdir(exist_ok=True)
(login/'bash').write_text('#!/usr/bin/bash\nif [ "${1:-}" = -lc ]; then\n printf "login PATH reordered before payload\\n" >&2\n export PATH=/usr/bin\n exec /usr/bin/bash -c "$2"\nfi\nexec /usr/bin/bash "$@"\n')
(login/'bash').chmod(0o755)
sentinel=lab/'sentinel-tmp/fm-node.tar.xz'; sentinel.write_bytes(b'pre-existing archive sentinel: preserve this\n')
sentinel_hash=hashlib.sha256(sentinel.read_bytes()).hexdigest()
print('portable backend real path:', (minimal/'shasum').resolve(), flush=True)
results=[]
for name,path,old in [('old-installer-login-reordered',str(login)+':'+os.environ['PATH'],True),('portable-shasum',str(minimal),False),('login-reordered',str(login)+':'+os.environ['PATH'],False)]:
    temp=lab/'tmp'/name; temp.mkdir(exist_ok=True)
    env=os.environ.copy(); env.update(PATH=path,HOME=str(lab/'home'),TMPDIR=str(temp),FM_LINT_JOBS='1',CHECKSUM_OLD=str(int(old)),CHECKSUM_OLD_SCRIPT=str(oldbin/'fm-remote-hands.sh'))
    for key in ['FM_ROOT_OVERRIDE','FM_HOME','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
        env.pop(key,None)
    command=['prlimit','--as=536870912:536870912','--','bwrap','--ro-bind','/','/','--dev','/dev','--proc','/proc','--bind',str(lab),str(lab),'--bind',str(lab/'sentinel-tmp'),'/tmp','--unshare-user','--unshare-pid','--unshare-net','--die-with-parent','/usr/bin/bash',str(lab/'focused.sh')]
    # PATH is intentionally narrow in the child, so resolve launcher programs first.
    command[0]=shutil.which('prlimit'); command[3]=shutil.which('bwrap')
    proc=subprocess.run(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60)
    leftovers=list(temp.iterdir())
    preserved=hashlib.sha256(sentinel.read_bytes()).hexdigest()==sentinel_hash
    expected_code=1 if old else 0
    okay=proc.returncode==expected_code and preserved and not leftovers
    log=f'{name}: process virtual-memory hard cap=512MiB; FM_LINT_JOBS=1; network namespace isolated\n'+proc.stdout+f'\nactual_exit={proc.returncode} expected_exit={expected_code}\nsentinel_preserved={preserved} SHA256={sentinel_hash}\nfixture_cleanup_complete={not leftovers}\n'
    (evidence/('fix2-'+name+'.log')).write_text(log)
    print(name, 'exit=',proc.returncode,'sentinel=',preserved,'cleanup=',not leftovers, 'log=', evidence/('fix2-'+name+'.log'),flush=True)
    results.append(dict(name=name,pass_=okay,exit=proc.returncode,sentinel_preserved=preserved,cleanup=not leftovers))
(evidence/'fix2-regression-results.json').write_text(json.dumps(results,indent=2)+'\n')
assert all(r['pass_'] for r in results),results
