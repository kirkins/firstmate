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
    for mode in ['good','wrong','missing','verifier-error']:
        for d in ['tmp','install']:
            for p in (live/d).iterdir():
                if p.is_dir():shutil.rmtree(p)
                else:p.chmod(0o600);p.unlink()
        dest=live/('clone-'+mode)
        env=os.environ.copy();env.update(PATH=str(live/'transport')+':/usr/bin',REMOTE_PATH=str(live/'tools')+':/usr/local/bin:/usr/bin',HOME=str(live/'home'),FM_HOME=str(live/'home'),FM_REMOTE_HANDS='1',FM_REMOTE_HANDS_SECRET='disposable/fixture',FM_LINT_JOBS='1',HTTPS_PORT=str(server.server_port),LIVE_CERT=str(live/'cert.pem'),LIVE_MODE=mode,GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
        for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(key,None)
        command=[str(root/'bin/fm-remote-hands.sh'),'prepare','--name','checksum-local','--repo','file://'+str(live/'repo'),'--dest',str(dest),'--node-major','26']
        proc=subprocess.run(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=40)
        installed=(live/'install/bin/node').is_file(); cloned=(dest/'.git').is_dir(); downloaded=(live/'tmp/fm-node.tar.xz').exists(); original=(live/'tmp'/archive.name).exists()
        okay=(proc.returncode==0 and installed and cloned and 'fm-node.tar.xz: OK' in proc.stdout and 'v26.10.0' in proc.stdout) if mode=='good' else (proc.returncode!=0 and not installed and not cloned and 'real tar extraction requested' not in proc.stderr and 'node tarball checksum verification failed' in proc.stderr)
        okay=okay and downloaded and not original
        record=dict(mode=mode,exit=proc.returncode,installed=installed,cloned=cloned,downloaded_as_fm_node=downloaded,distribution_filename_absent=not original,pass_=okay,requests=[r['path'] for r in requests if r['mode']==mode])
        log='Real fm-remote-hands prepare, disposable bubblewrap namespace, local TLS origin, actual curl/sha256sum/tar/git, archived installed Node 26.10.0. No external downloads, cloud, package installs, or production credentials.\nprocess virtual-memory hard cap=512MiB; FM_LINT_JOBS=1\ncommand: '+shlex.join(command)+'\nstdout:\n'+proc.stdout+'stderr:\n'+proc.stderr+'observed state:\n'+json.dumps(record,indent=2)+'\n'
        (lab/('live-'+mode+'.log')).write_text(log)
        results.append(record);print(json.dumps(record),flush=True)
finally:server.shutdown();server.server_close();thread.join()
(lab/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
assert all(r['pass_'] for r in results),results
