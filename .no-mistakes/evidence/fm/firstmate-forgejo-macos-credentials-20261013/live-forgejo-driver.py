import http.server, json, os, pathlib, shutil, ssl, subprocess, threading, time

ROOT = pathlib.Path.cwd()
LAB = ROOT / '.test-forgejo/live'
EVIDENCE = pathlib.Path('/home/kirkins/.no-mistakes/evidence/01M4ST8PQHRYNYFWM13WNDMBHP')
TOKEN = 'syntheticforgejotoken0123456789'
HOST = 'lab.forgejo.test'
URL = f'https://{HOST}/owner/repo/pulls/9'
HEAD = 'a' * 40
STALE = 'b' * 40
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'GIT_'))}
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(ROOT / '.test-forgejo/tmp'))
calls, results = [], []
state = {}

class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def handle_request(self):
        auth = self.headers.get('Authorization') == 'token ' + TOKEN
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        calls.append(dict(method=self.command, path=self.path, authenticated=auth, body=body.decode()))
        code, response = 200, {}
        if not auth:
            code, response = 401, {'message': 'unauthorized'}
        elif self.command == 'POST' and self.path.endswith('/merge'):
            if state.get('reject_merge'):
                code, response = 409, {'message': 'disposable merge conflict'}
            else:
                state['merged'] = True
                if state.get('move_after_merge'): state['head'] = STALE
        elif self.path.endswith('/status'):
            response = {'state': state.get('status', 'success'), 'total_count': state.get('count', 1), 'statuses': []}
        elif self.path == '/api/v1/repos/owner/repo/pulls/9':
            response = dict(state='closed' if state.get('merged') else state.get('state', 'open'),
                            draft=state.get('draft', False), merged=state.get('merged', False),
                            mergeable=state.get('mergeable', True), head={'sha': state.get('head', HEAD)})
        else: code, response = 404, {'message': 'unknown disposable endpoint'}
        payload = json.dumps(response).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload))); self.end_headers()
        self.wfile.write(payload)
    do_GET = handle_request
    do_POST = handle_request

def run(args, e=None, input=None, timeout=35):
    return subprocess.run(args, env=e or env, input=input, text=True, capture_output=True, timeout=timeout)

def fixture(name, **changes):
    state.clear(); state.update(changes); calls.clear()
    home = LAB / name
    for child in ('state','data','config','project','wt'):
        (home / child).mkdir(parents=True)
    for child in ('project', 'wt'):
        assert run(['git','-C',str(home/child),'init','-q']).returncode == 0
    assert run(['git','-C',str(home/'project'),'remote','add','origin',f'https://{HOST}/owner/repo.git']).returncode == 0
    meta = '\n'.join(['window=fm-task-lab',f'worktree={home}/wt',f'project={home}/project','kind=ship','mode=no-mistakes']) + '\n'
    (home/'state/task-lab.meta').write_text(meta)
    e = dict(env, FM_ROOT_OVERRIDE=str(ROOT), FM_HOME=str(home), FM_STATE_OVERRIDE=str(home/'state'),
             FM_DATA_OVERRIDE=str(home/'data'), FM_CONFIG_OVERRIDE=str(home/'config'), FM_PROJECTS_OVERRIDE=str(home/'projects'),
             PATH=str(LAB/'transport') + ':' + env['PATH'])
    return home, e

def command(label, args, e):
    p = run(args, e)
    results.append(dict(label=label, command=args, exit=p.returncode, stdout=p.stdout, stderr=p.stderr,
                        requests=list(calls)))
    return p

def credential(value):
    p = run(['secret-tool','store','--label=Disposable Firstmate verification','service',HOST+'/forgejo-cli/omarchy'], input=value)
    assert p.returncode == 0, p.stderr

daemon = server = None
try:
    LAB.mkdir(parents=True)
    daemon = subprocess.Popen(['gnome-keyring-daemon','--foreground','--unlock','--components=secrets',
                               '--control-directory='+str(ROOT/'.kr/c')], env=env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    daemon.stdin.write('disposable-lab-password'); daemon.stdin.close(); time.sleep(0.5)
    credential(TOKEN)
    cert, key = LAB/'cert.pem', LAB/'key.pem'
    p = run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN='+HOST,
             '-addext','subjectAltName=DNS:'+HOST,'-keyout',str(key),'-out',str(cert)])
    assert p.returncode == 0, p.stderr
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0), API)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    (LAB/'transport').mkdir(exist_ok=True)
    wrapper = LAB/'transport/curl'
    wrapper.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" >> "'+str(LAB/'curl-argv.log')+'"\nexec /usr/bin/curl --noproxy "*" --cacert "'+str(cert)+'" --connect-to '+HOST+':443:127.0.0.1:'+str(port)+' "$@"\n')
    wrapper.chmod(0o755)
    home, e = fixture('register')
    p = command('Register using real Linux keyring and HTTPS', ['bash',str(ROOT/'bin/fm-pr-check.sh'),'task-lab',URL],e)
    assert p.returncode == 0, p.stderr
    assert 'pr_head='+HEAD in (home/'state/task-lab.meta').read_text()
    p = command('Copied poll remains silent while open', ['bash',str(home/'state/task-lab.check.sh')],e)
    assert p.returncode == 0 and p.stdout == '', p.stderr
    state['merged'] = True
    p = command('Copied poll reports merged', ['bash',str(home/'state/task-lab.check.sh')],e)
    assert p.returncode == 0 and p.stdout == 'merged\n', p.stderr
    p = command('Canonical poll reports merged', ['bash',str(ROOT/'bin/fm-pr-poll.sh'),'--validated','forgejo',URL,HOST,'owner/repo','9'],e)
    assert p.returncode == 0 and p.stdout == 'merged\n', p.stderr
    # Trace the public API helper and both command interfaces with the real token tool.
    (home/'response.json').touch()
    p = command('Traced API request', ['bash','-x','-c','. "$1"; fm_pr_forgejo_api GET "$2" /repos/owner/repo/pulls/9 "$3"',
                                     '--',str(ROOT/'bin/fm-pr-lib.sh'),HOST,str(home/'response.json')],e)
    assert p.returncode == 0 and p.stdout.strip() == '200', p.stderr
    p = command('Traced canonical poll', ['bash','-x',str(ROOT/'bin/fm-pr-poll.sh'),'--validated','forgejo',URL,HOST,'owner/repo','9'],e)
    assert p.stdout == 'merged\n'
    home, e = fixture('merge')
    with (home/'state/task-lab.meta').open('a') as f: f.write('pr_head='+STALE+'\n')
    p = command('Merge verifies current head and records confirmed outcome', ['bash',str(ROOT/'bin/fm-pr-merge.sh'),'task-lab',URL],e)
    assert p.returncode == 0, p.stderr
    assert 'disagrees with the live head' in p.stderr
    assert any(c['path'].endswith('/commits/'+HEAD+'/status') for c in calls)
    assert (home/'state/task-lab.merge-authority').is_file()
    assert URL in (home/'state/.wake-queue').read_text()
    results[-1]['persisted_metadata'] = (home/'state/task-lab.meta').read_text()
    results[-1]['persisted_authority'] = (home/'state/task-lab.merge-authority').read_text()
    results[-1]['persisted_wake'] = (home/'state/.wake-queue').read_text()
    for name, changes in [('draft',{'draft':True}),('closed',{'state':'closed'}),('conflict',{'mergeable':False}),
                          ('red',{'status':'failure'}),('no-checks',{'count':0}),('wrong-repository',{}),('wrong-host',{}),
                          ('rejected-merge',{'reject_merge':True}),('head-moved-after-merge',{'move_after_merge':True})]:
        home, e = fixture(name, **changes)
        if name in ('wrong-repository','wrong-host'):
            origin = f'https://{HOST}/owner/other.git' if name == 'wrong-repository' else 'https://other.forgejo.test/owner/repo.git'
            assert run(['git','-C',str(home/'project'),'remote','set-url','origin',origin]).returncode == 0
        if name in ('draft','wrong-repository','wrong-host'):
            before = (home/'state/task-lab.meta').read_bytes()
            p = command('Registration refuses '+name,['bash',str(ROOT/'bin/fm-pr-check.sh'),'task-lab',URL],e)
            assert p.returncode != 0 and (home/'state/task-lab.meta').read_bytes() == before
            assert not (home/'state/task-lab.check.sh').exists()
        label = 'Post-merge head movement is reported loudly' if name == 'head-moved-after-merge' else 'Guard refuses '+name
        p = command(label, ['bash',str(ROOT/'bin/fm-pr-merge.sh'),'task-lab',URL],e)
        if name == 'head-moved-after-merge':
            assert p.returncode == 0 and 'commits this run did not verify may have landed' in p.stderr
            assert URL in (home/'state/.wake-queue').read_text()
            continue
        assert p.returncode != 0, name
        if name not in ('rejected-merge','head-moved-after-merge'):
            assert not any(c['method'] == 'POST' for c in calls), name
            assert not (home/'state/task-lab.merge-authority').exists(), name
        assert not (home/'state/.wake-queue').exists(), name
    home, e = fixture('missing-tool')
    restricted = LAB/'without-secret-tool'; restricted.mkdir()
    for tool in ('bash','uname','dirname','grep','tail','cut','stat','sed','cat','awk','env','chmod','wc','tr','date','mkdir','cp','mv','ps','hostname','python3','perl','sh','touch','getconf','jq','sleep','sort','sha256sum','shasum','readlink','realpath','head','id','rm','mktemp','rmdir','ln','basename','git'):
        path = shutil.which(tool)
        if path: (restricted/tool).symlink_to(path)
    (restricted/'curl').symlink_to(wrapper)
    e['PATH'] = str(restricted)
    for script in ('fm-pr-check.sh','fm-pr-merge.sh'):
        p = command(script+' names missing native tool',['bash',str(ROOT/'bin'/script),'task-lab',URL],e)
        assert p.returncode != 0 and 'requires secret-tool on PATH' in p.stderr, p.stderr
    p = command('Poll stays silent for missing native tool',['bash',str(ROOT/'bin/fm-pr-poll.sh'),'--validated','forgejo',URL,HOST,'owner/repo','9'],e)
    assert p.stdout == '' and not calls
    for name, value in [('empty-token',''),('malformed-token','bad token bytes'),('short-token','a'*19),('long-token','a'*257),('missing-token',None)]:
        if value is None:
            assert run(['secret-tool','clear','service',HOST+'/forgejo-cli/omarchy']).returncode == 0
        else: credential(value)
        home, e = fixture(name)
        before = (home/'state/task-lab.meta').read_bytes()
        for script in ('fm-pr-check.sh','fm-pr-merge.sh'):
            p = command(script+' refuses '+name,['bash',str(ROOT/'bin'/script),'task-lab',URL],e)
            assert p.returncode != 0
            assert (home/'state/task-lab.meta').read_bytes() == before
        p = command('Poll stays silent for '+name,['bash',str(ROOT/'bin/fm-pr-poll.sh'),'--validated','forgejo',URL,HOST,'owner/repo','9'],e)
        assert p.stdout == '' and not calls
        assert not (home/'state/task-lab.check.sh').exists()
    # All credential bytes must stay absent from CLI arguments, traces, and durable state.
    assert TOKEN not in json.dumps(results)
    assert TOKEN not in (LAB/'curl-argv.log').read_text()
    for path in LAB.glob('*/state/*'):
        if path.is_file(): assert TOKEN.encode() not in path.read_bytes(), str(path)
    assert all(c['authenticated'] for r in results for c in r['requests'])
    results.append({'label':'Token privacy','result':'All real HTTPS requests authenticated; no synthetic token in argv, traces, output, metadata, authority, or wakes.'})
    (EVIDENCE/'live-forgejo-transcript.json').write_text(json.dumps(results,indent=2)+'\n')
    print('Real CLI, secret-tool, private keyring, curl, TLS, registration, merge, polling, refusal guards, and token privacy verified.')
finally:
    (EVIDENCE/'live-forgejo-transcript.json').write_text(json.dumps(results,indent=2)+'\n')
    if server: server.shutdown(); server.server_close()
    if daemon:
        daemon.terminate()
        try: daemon.wait(timeout=5)
        except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()
