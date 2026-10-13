import pathlib, os, subprocess, tarfile, lzma, hashlib, json, ssl, http.server, threading, shutil, shlex, sys
root=pathlib.Path.cwd(); lab=root/'.checksum-lab'; live=lab/'live'; live.mkdir(exist_ok=True)
evidence=pathlib.Path('/home/kirkins/.no-mistakes/evidence/01M4V016HPH5A3J4VTRRX6MZKS')
if len(sys.argv)==1:
    archive=live/'node-v26.10.0-linux-aarch64.tar.xz'
    with lzma.open(archive,'wb',preset=0) as stream:
        with tarfile.open(fileobj=stream,mode='w|') as tar:
            tar.add('/usr/bin/node',arcname='node-v26.10.0/bin/node')
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=nodejs.org','-addext','subjectAltName=DNS:nodejs.org','-keyout',str(live/'key.pem'),'-out',str(live/'cert.pem')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    repo=live/'repo';repo.mkdir(exist_ok=True); (repo/'README.md').write_text('Disposable checksum live validation repository\n')
    git_env=os.environ.copy();git_env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Test',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Test',GIT_COMMITTER_EMAIL='test@example.invalid')
    for args in ([] if (repo/'.git').exists() else [['init','-q',str(repo)],['-C',str(repo),'add','README.md'],['-C',str(repo),'commit','-qm','fixture']]):subprocess.run(['git',*args],env=git_env,check=True)
    for d in ['tmp','install','home','transport','tools']:(live/d).mkdir(exist_ok=True)
    (live/'transport/kubectl').write_text('#!/usr/bin/bash\nprintf local-disposable-only | /usr/bin/base64\n')
    (live/'transport/sbx').write_text('''#!/usr/bin/python3
import os,sys,shlex,subprocess
if sys.argv[1]=='login':
    sys.stdin.read(); sys.exit(0)
assert sys.argv[1:3]==['--cloud','exec']
assert sys.argv[4]=='--'
args=shlex.split(' '.join(sys.argv[5:]))
assert args[:2]==['bash','-lc']
args[2]='export PATH='+shlex.quote(os.environ['REMOTE_PATH'])+'; '+args[2]
sys.exit(subprocess.call(args))
''')
    (live/'tools/sudo').write_text('''#!/usr/bin/bash
if [ "$1" = apt-get ]; then printf 'sandbox prerequisites already provisioned; package installation disabled\\n' >&2; exit 0; fi
[ "$1" = tar ] || exit 99
printf 'real tar extraction requested\\n' >&2
exec /usr/bin/tar "${@:2}"
''')
    (live/'tools/curl').write_text('''#!/usr/bin/bash
/usr/bin/curl --noproxy '*' --connect-to "nodejs.org:443:127.0.0.1:$HTTPS_PORT" --cacert "$LIVE_CERT" "$@" || exit $?
if [ "$LIVE_MODE" = verifier-error ] && [ "${2:-}" = -o ]; then /usr/bin/chmod 000 "$3"; fi
''')
    for p in [live/'transport/kubectl',live/'transport/sbx',live/'tools/sudo',live/'tools/curl']:p.chmod(0o755)
    command=['prlimit','--as=536870912:536870912','--','bwrap','--ro-bind','/','/','--dev','/dev','--proc','/proc','--bind',str(lab),str(lab),'--bind',str(live/'tmp'),'/tmp','--bind',str(live/'install'),'/usr/local','--ro-bind','/usr/bin/false','/usr/bin/node','--unshare-user','--unshare-pid','--unshare-net','--die-with-parent','/usr/bin/python3',str(lab/'live.py'),'inside']
    subprocess.run(command,check=True,timeout=120)
    sys.exit()
import resource
print('enforced RLIMIT_AS:', resource.getrlimit(resource.RLIMIT_AS), 'FM_LINT_JOBS:', os.environ.get('FM_LINT_JOBS'), flush=True)
archive=live/'node-v26.10.0-linux-aarch64.tar.xz'; digest=hashlib.sha256(archive.read_bytes()).hexdigest(); requests=[]; mode='good'
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(dict(mode=mode,path=self.path))
        if self.path.endswith('/SHASUMS256.txt'):
            body=(('f'*64+'  unrelated.tar.xz\n') if mode=='missing' else (('0'*64 if mode=='wrong' else digest)+'  '+archive.name+'\n')).encode()
        elif self.path.endswith('/'+archive.name):body=archive.read_bytes()
        elif self.path=='/dist/latest-v26.x/':body=('<a href="'+archive.name+'">Node 26</a>').encode()
        else:self.send_error(404);return
        self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler); ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(str(live/'cert.pem'),str(live/'key.pem'));server.socket=ctx.wrap_socket(server.socket,server_side=True)
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
results=[]
try:
    for mode in os.environ.get('FIX2_CASES','old-installer-login-reordered,portable-shasum,login-reordered').split(','):
        for d in ['tmp','install']:
            for p in (live/d).iterdir():
                if p.is_dir():shutil.rmtree(p)
                else:p.chmod(0o600);p.unlink()
        dest=live/('clone-'+mode)
        env=os.environ.copy();env.update(PATH=str(live/'transport')+':/usr/bin',REMOTE_PATH=str(live/'tools')+':/usr/local/bin:/usr/bin',HOME=str(live/'home'),FM_HOME=str(live/'home'),FM_REMOTE_HANDS='1',FM_REMOTE_HANDS_SECRET='disposable/fixture',FM_LINT_JOBS='1',HTTPS_PORT=str(server.server_port),LIVE_CERT=str(live/'cert.pem'),LIVE_MODE=mode,GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
        for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(key,None)
        command=[str(lab/'old-bin/fm-remote-hands.sh' if mode.startswith('old-') else root/'bin/fm-remote-hands.sh'),'prepare','--name','checksum-local','--repo','file://'+str(live/'repo'),'--dest',str(dest),'--node-major','26']
        tools=live/('tools-'+mode); tools.mkdir(exist_ok=True)
        for tool in ['sudo','curl']:
            (tools/tool).symlink_to(live/'tools'/tool)
        portable=mode=='portable-shasum'
        if portable:
            (tools/'sha256sum').write_text('#!/usr/bin/bash\nprintf "real /usr/bin/core_perl/shasum -a 256 backend invoked\\n" >&2\nexec /usr/bin/core_perl/shasum -a 256 "$@"\n')
            (tools/'sha256sum').chmod(0o755)
        else:
            (tools/'bash').write_text('#!/usr/bin/bash\nif [ "${1:-}" = -lc ]; then\n printf "login PATH reordered before payload\\n" >&2\n export PATH=/usr/bin\n exec /usr/bin/bash -c "$2"\nfi\nexec /usr/bin/bash "$@"\n')
            (tools/'bash').chmod(0o755)
        env['REMOTE_PATH']=str(tools)+':/usr/local/bin:'+str(lab/'portable-bin') if portable else str(tools)+':/usr/local/bin:/usr/bin'
        env['PATH']=str(live/'transport')+':'+str(tools)+':/usr/bin'
        sentinel=lab/'sentinel-tmp/fm-node.tar.xz'; before=hashlib.sha256(sentinel.read_bytes()).hexdigest()
        driver=live/('assert-'+mode+'.sh')
        driver.write_text("""#!/usr/bin/bash
trap '/usr/bin/rm -rf -- "$LIVE_TMP"/* "$LIVE_INSTALL"/* "$LIVE_DEST"; printf "fixture EXIT cleanup ran\\n"' EXIT
"$@"; status=$?
printf 'product_exit=%s\\n' "$status"
installed=no; cloned=no
[ ! -f "$LIVE_INSTALL/bin/node" ] || installed=yes
[ ! -d "$LIVE_DEST/.git" ] || cloned=yes
printf 'before cleanup: real_node_installed=%s real_repo_cloned=%s\\n' "$installed" "$cloned"
if [ "$LIVE_OLD" = 1 ]; then
  [ "$status" -ne 0 ] && [ "$installed" = no ] && [ "$cloned" = no ] || { printf 'not ok - verification failure continued to real extraction and cloning\\n'; exit 1; }
else
  [ "$status" = 0 ] && [ "$installed" = yes ] && [ "$cloned" = yes ] || { printf 'not ok - valid checksum did not complete preparation\\n'; exit 1; }
fi
printf 'ok - valid checksum completed real preparation\\n'
""")
        env.update(LIVE_TMP=str(live/'tmp'),LIVE_INSTALL=str(live/'install'),LIVE_DEST=str(dest),LIVE_OLD=str(int(mode.startswith('old-'))))
        proc=subprocess.run(['/usr/bin/bash',str(driver),*command],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=40)
        old=mode.startswith('old-')
        preserved=hashlib.sha256(sentinel.read_bytes()).hexdigest()==before
        cleanup=not list((live/'tmp').iterdir()) and not list((live/'install').iterdir()) and not dest.exists()
        okay=proc.returncode==(1 if old else 0) and preserved and cleanup
        okay=okay and ('real_node_installed=yes real_repo_cloned=yes' in proc.stdout)
        okay=okay and ('FAILED open or read' in proc.stdout if old else 'fm-node.tar.xz: OK' in proc.stdout)
        if portable: okay=okay and 'real /usr/bin/core_perl/shasum -a 256 backend invoked' in proc.stderr
        else: okay=okay and 'login PATH reordered before payload' in proc.stderr
        record=dict(mode=mode,regression_exit=proc.returncode,pass_=okay,sentinel_preserved=preserved,fixture_cleanup_complete=cleanup,requests=[r['path'] for r in requests if r['mode']==mode])
        log='Unchanged preparation CLI in isolated local shell transport; real curl via local TLS origin, real SHA backend, real tar, real Node26, real git. Portable case uses the test SHA-command adapter to real shasum; reordering cases restore PATH in transport after simulated login initialization. No native macOS/cloud coverage claimed.\nprocess address-space hard cap=536870912 bytes; FM_LINT_JOBS=1; network namespace isolated\ncommand: '+shlex.join(command)+'\nstdout:\n'+proc.stdout+'stderr:\n'+proc.stderr+'observed state:\n'+json.dumps(record,indent=2)+'\n'
        (lab/('fix2-live-'+mode+'.log')).write_text(log)
        results.append(record);print(json.dumps(record),flush=True)
finally:server.shutdown();server.server_close();thread.join()
(lab/'fix2-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
assert all(r['pass_'] for r in results),results
