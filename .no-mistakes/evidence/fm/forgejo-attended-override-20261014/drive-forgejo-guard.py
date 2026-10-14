#!/usr/bin/env python3
"""Drive Firstmate's real merge CLI, curl and jq against a disposable TLS API.
The API supplies Forgejo protocol data; secret-tool supplies a test-only token.
No production endpoint, keyring, or fleet state is used. Run from the gate cwd.
"""
import http.server, ssl, threading, pathlib, subprocess, os, json, shutil, sys
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/home/kirkins/.no-mistakes/evidence/01M4WBAE1XX2YA2VTAA89N489A')
SCRATCH = ROOT / '.test-forgejo-live' / 'cli'
HOST = 'git.lobbykit.net'
URL = f'https://{HOST}/hermes/lobbykit-ios/pulls/92'
HEAD = '239fda5000000000000000000000000000000000'
OTHER = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
TOKEN = 'disposableforgejotoken0123456789abcdef'
SCRATCH.mkdir(parents=True, exist_ok=True)
clean_env = dict(os.environ)
for k in list(clean_env):
    if k.startswith('FM_') or k.startswith('GIT_') or k.startswith('TASKS_AXI_'):
        del clean_env[k]
clean_env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(SCRATCH), HOME=str(SCRATCH / 'user-home'))
(SCRATCH / 'user-home').mkdir(exist_ok=True)
for key, subdir in [('XDG_CONFIG_HOME','config'),('XDG_DATA_HOME','data'),('XDG_STATE_HOME','state'),('XDG_CACHE_HOME','cache')]:
    target=SCRATCH/'user-home'/subdir
    target.mkdir(exist_ok=True)
    clean_env[key]=str(target)
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', f'/CN={HOST}', '-addext', f'subjectAltName=DNS:{HOST}', '-keyout', str(SCRATCH / 'key.pem'), '-out', str(SCRATCH / 'cert.pem')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=clean_env)
CURRENT = {}
class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.handle_api()
    def do_POST(self): self.handle_api()
    def handle_api(self):
        c = CURRENT
        body = self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode()
        authenticated = self.headers.get('Authorization') == f'token {TOKEN}'
        event = dict(method=self.command, path=self.path, body=body, authenticated=authenticated)
        c['requests'].append(event)
        code = 200
        if not authenticated:
            code, answer = 401, {'message':'test token required'}
        elif self.command == 'GET' and self.path == '/api/v1/repos/hermes/lobbykit-ios/pulls/92':
            answer = dict(state=c.get('state', 'open'), draft=c.get('draft', False), merged=c.get('already_merged', False), mergeable=c.get('mergeable', True), head={'sha':c.get('head', HEAD)})
            if c.get('post_called') and not c.get('unconfirmed') and c.get('merge_http',200) < 300:
                answer.update(state='closed', merged=True, head={'sha':c.get('merged_head', c.get('head',HEAD))})
        elif self.command == 'GET' and self.path.endswith('/status'):
            answer = c.get('status', {'state':'pending','total_count':0,'statuses':[]})
            if c.get('late_record'):
                # Publish through the real record owner's public interface during preflight.
                proc = subprocess.run(['bash',str(ROOT/'bin/fm-afk-contract.sh'),'enter','--words','Test record created during status preflight'],env=c['posture_env'],capture_output=True,text=True)
                c['late_record_result'] = {'code':proc.returncode, 'output':proc.stdout+proc.stderr}
                if proc.returncode: code, answer = 500, {'message':'record publication failed'}
        elif self.command == 'POST' and self.path == '/api/v1/repos/hermes/lobbykit-ios/pulls/92/merge':
            c['post_called'] = True
            code = c.get('merge_http',200)
            answer = {'message':'local API accepted test merge' if code < 300 else 'local API refused test merge'}
            c['meta_at_post'] = (c['state_dir']/'task-x1.meta').read_text()
        else:
            code, answer = 404, {'message':'unexpected fixture endpoint'}
        event.update(response_code=code,response=answer)
        encoded = json.dumps(answer).encode()
        self.send_response(code)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(str(SCRATCH/'cert.pem'), str(SCRATCH/'key.pem'))
server.socket = ctx.wrap_socket(server.socket, server_side=True)
thread = threading.Thread(target=server.serve_forever,daemon=True)
thread.start()
fakebin = SCRATCH/'credential-and-routing'
fakebin.mkdir(exist_ok=True)
# curl is not simulated: only add an isolated connection route and trust root.
# Fail closed for any unrecognized URL, rather than falling through to the network.
(fakebin/'curl').write_text(f'''#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    https://*) case "$arg" in https://{HOST}/api/v1/*) ;; *) exit 98 ;; esac ;;
  esac
done
exec {shutil.which('curl')} --noproxy '*' --cacert '{SCRATCH / 'cert.pem'}' --connect-to '{HOST}:443:127.0.0.1:{server.server_port}' "$@"
''')
(fakebin/'secret-tool').write_text(f'''#!/bin/bash
[ "$*" = 'lookup service {HOST}/forgejo-cli/omarchy' ] || exit 1
printf '%s' '{TOKEN}'
''')
for p in fakebin.iterdir(): p.chmod(0o700)
BASE = dict(clean_env, PATH=str(fakebin)+os.pathsep+os.environ['PATH'], FM_ROOT_OVERRIDE=str(ROOT))
selected=set(sys.argv[1:])
results=[r for r in json.loads((EVIDENCE/'live-cli-results.json').read_text()) if r['name'] not in selected] if selected else []
transcript=[]
def run(name, args=None, expected=1, expected_text=None, should_post=False, setup=None, url=URL, **settings):
    global CURRENT
    if selected and name not in selected: return
    d=SCRATCH/name
    for child in ['home/data','home/config','home/state','wt','project']:
        (d/child).mkdir(parents=True,exist_ok=True)
    state=d/'home/state'
    env=dict(BASE,FM_HOME=str(d/'home'))
    # Every fixture Git operation is local and ignores global configs/hooks.
    for repo in [d/'wt',d/'project']:
        subprocess.run(['git','init','-q',str(repo)],env=env,check=True)
    subprocess.run(['git','-C',str(d/'wt'),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-q','--allow-empty','-m','Disposable task'],env=env,check=True)
    task_head=subprocess.run(['git','-C',str(d/'wt'),'rev-parse','HEAD'],env=env,check=True,capture_output=True,text=True).stdout.strip()
    subprocess.run(['git','-C',str(d/'wt'),'update-ref','refs/remotes/origin/main',task_head],env=env,check=True)
    subprocess.run(['git','-C',str(d/'project'),'remote','add','origin',f'https://{HOST}/hermes/lobbykit-ios.git'],env=env,check=True)
    (state/'task-x1.meta').write_text(f'window=fm-task-x1\nworktree={d}/wt\nproject={d}/project\nkind=ship\nmode=no-mistakes\n')
    shutil.copyfile(ROOT/'.tasks.toml',d/'home/.tasks.toml')
    (d/'home/data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    c=dict(settings,requests=[],state_dir=state)
    posture_env=dict(env,FM_AFK_MODE=settings.get('posture','away'))
    c['posture_env']=posture_env
    CURRENT=c
    if setup: setup(d,env,c)
    if settings.get('pre_record'):
        subprocess.run(['bash',str(ROOT/'bin/fm-afk-contract.sh'),'enter','--words','Disposable record denies waiver'],env=posture_env,check=True,capture_output=True)
    cmd=['bash',settings.get('entrypoint','bin/fm-pr-merge.sh'),'task-x1',url]+(args if args is not None else ['--attended-override','--allow-no-checks',URL])
    proc=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=45)
    record=(state/'task-x1.merge-authority')
    queue=state/'.wake-queue'
    obs=dict(name=name,command=cmd,returncode=proc.returncode,stdout=proc.stdout,stderr=proc.stderr,requests=c['requests'],metadata=(state/'task-x1.meta').read_text(),authority=record.read_text() if record.exists() else None,wake_queue=queue.read_text() if queue.exists() else None,poll_armed=(state/'task-x1.check.sh').exists(),meta_at_post=c.get('meta_at_post'),late_record_result=c.get('late_record_result'))
    failures=[]
    if proc.returncode != expected: failures.append(f'exit {proc.returncode}, expected {expected}')
    if bool(c.get('post_called')) != should_post: failures.append('unexpected merge POST presence/absence')
    if expected_text and expected_text not in proc.stdout+proc.stderr: failures.append(f'missing expected diagnostic: {expected_text}')
    if should_post and expected == 0 and not settings.get('unconfirmed'):
        if not obs['authority'] or obs['authority'].splitlines()[-1]!=settings.get('expected_authority','attended'): failures.append('expected authority absent')
        if not obs['wake_queue'] or URL not in obs['wake_queue']: failures.append('confirmed landing proof absent')
        if f'pr={URL}' not in obs['meta_at_post'] or f'pr_head={HEAD}' not in obs['meta_at_post']: failures.append('PR/head not recorded before POST')
    if not should_post and (obs['authority'] or obs['wake_queue']): failures.append('refusal falsely recorded authority or landing')
    if settings.get('unconfirmed') and (obs['wake_queue'] or not obs['poll_armed']): failures.append('unconfirmed merge lost poll or claimed landing')
    if settings.get('style') and json.loads(next(x['body'] for x in obs['requests'] if x['method']=='POST'))['Do'] != settings['style']: failures.append('wrong merge style')
    obs.update(result='fail' if failures else 'pass',failures=failures)
    results.append(obs)
    print(f'{name}: {obs["result"]}',flush=True)
def set_remote(d,env,c):
    subprocess.run(['git','-C',str(d/'project'),'remote','set-url','origin','https://elsewhere.invalid/other/repo.git'],env=env,check=True)
def wrong_pr(d,env,c):
    with (d/'home/state/task-x1.meta').open('a') as f: f.write(f'pr=https://{HOST}/hermes/lobbykit-ios/pulls/93\n')
def hold(d,env,c):
    subprocess.run(['bash','bin/fm-captain-hold.sh','hold','task-x1','--reason','approval pending','--title','Disposable merge test','--repo','fixture'],env=env,check=True,capture_output=True)
def stale(d,env,c):
    with (d/'home/state/task-x1.meta').open('a') as f: f.write(f'pr_head={OTHER}\n')
def malformed_record(d,env,c):
    (d/'home/state/.afk-contract').write_text('damaged posture record\n')
def unreadable_hold(d,env,c):
    (d/'home/data/backlog.md').chmod(0)
try:
    base_bin=SCRATCH/'base/bin'
    base_bin.mkdir(parents=True)
    for file in (ROOT/'bin').iterdir():
        if file.name not in ['fm-pr-merge.sh','fm-pr-lib.sh']: (base_bin/file.name).symlink_to(file)
    for name in ['fm-pr-merge.sh','fm-pr-lib.sh']:
        old=subprocess.run(['git','show','5a8965c825fa99ecd2b1ec357c0fbcd9c8b96742:bin/'+name],env=clean_env,check=True,capture_output=True)
        (base_bin/name).write_bytes(old.stdout)
    run('before-fix-no-checks',args=[],entrypoint=str(base_bin/'fm-pr-merge.sh'),expected_text='"none", not success')
    run('before-fix-named-waiver',entrypoint=str(base_bin/'fm-pr-merge.sh'),expected=2,expected_text='not supported on a Forgejo merge')
    run('no-waiver',args=[],expected_text='"none", not success')
    run('attended-alone',args=['--attended-override'],expected_text='"none", not success')
    run('named-waiver-default',expected=0,should_post=True,expected_text='no reported checks (explicitly waived)',style='squash')
    for style in ['squash','merge','rebase']:
        run('named-waiver-'+style,args=['--attended-override','--allow-no-checks',URL,'--','--'+style],expected=0,should_post=True,expected_text='no reported checks (explicitly waived)',style=style)
    bad=[('no-attended',['--allow-no-checks',URL]),('no-url',['--attended-override','--allow-no-checks']),('wrong-url',['--attended-override','--allow-no-checks',URL.replace('/92','/93')]),('malformed-url',['--attended-override','--allow-no-checks','92']),('trailing-slash',['--attended-override','--allow-no-checks',URL+'/']),('equals',['--attended-override','--allow-no-checks='+URL]),('duplicate',['--attended-override','--allow-no-checks',URL,'--allow-no-checks',URL]),('after-separator',['--attended-override','--','--allow-no-checks',URL])]
    for name,args in bad: run(name,args=args,expected=2)
    for name,url in [('github','https://github.com/example/repo/pull/92'),('gitlab','https://gitlab.invalid/group/repo/-/merge_requests/92')]:
        run('provider-'+name,url=url,expected=2,expected_text='applies only to Forgejo')
    for posture in ['away','quiet']:
        for timing in ['pre','late']:
            run(f'{posture}-{timing}',posture=posture,pre_record=timing=='pre',late_record=timing=='late',expected=2,expected_text='--allow-no-checks is attended-only')
        run(f'{posture}-green-without-waiver',args=[],posture=posture,pre_record=True,status={'state':'success','total_count':1,'statuses':[{'status':'success'}]},expected=0,should_post=True,expected_authority='away' if posture=='away' else 'attended',expected_text='successful combined commit status')
    run('malformed-posture-record',setup=malformed_record,expected=2,expected_text='--allow-no-checks is attended-only')
    for status in ['failure','pending','error']:
        run('reported-'+status,status={'state':status,'total_count':1,'statuses':[{'status':status}]},expected_text=f'"{status}", not success')
    malformed=[('count-string',{'state':'success','total_count':'0'}),('empty-state',{'state':'','total_count':1}),('fractional',{'state':'success','total_count':0.5}),('negative',{'state':'success','total_count':-1}),('bad-json-shape',[])]
    for name,status in malformed: run('unreadable-'+name,status=status,expected_text='could not be read')
    for name,kw,text in [('draft',{'draft':True},'the pull request is a draft'),('closed',{'state':'closed'},'not open'),('already-merged',{'already_merged':True},'already merged'),('conflict',{'mergeable':False},'not true'),('bad-head',{'head':'unreadable'},'head')]:
        run('guard-'+name,expected_text=text,**kw)
    run('guard-project-identity',setup=set_remote,expected_text='whose host is elsewhere.invalid, not git.lobbykit.net')
    run('guard-pr-identity',setup=wrong_pr,expected_text='bound')
    run('guard-captain-hold',setup=hold,expected_text='still held for the captain')
    run('guard-unreadable-hold',setup=unreadable_hold,expected_text='could not determine whether')
    run('guard-invalid-style',args=['--attended-override','--allow-no-checks',URL,'--','--method','rebase'],expected=2,expected_text='not supported on a Forgejo merge')
    run('guard-head-override',args=['--attended-override','--allow-no-checks',URL,'--','--sha',OTHER],expected_text='must not override the head')
    run('stale-recorded-head',setup=stale,expected=0,should_post=True,expected_text=f'recorded head {OTHER} disagrees with the live head {HEAD}')
    run('unconfirmed-outcome',expected=0,should_post=True,unconfirmed=True,expected_text='merge poll remains armed')
    run('moved-head-outcome',expected=0,should_post=True,merged_head=OTHER,expected_text=f'merged at head {OTHER} rather than the verified head {HEAD}')
    run('rejected-outcome',expected=1,should_post=True,merge_http=405,expected_text='HTTP 405')
finally:
    server.shutdown()
    server.server_close()
    (EVIDENCE/'live-cli-results.json').write_text(json.dumps(results,indent=2)+'\n')
    for obs in results:
        transcript.extend([f'=== {obs["name"]}: {obs["result"]} ===', '$ '+' '.join(obs['command']), f'exit={obs["returncode"]}',obs['stdout'].rstrip(),obs['stderr'].rstrip(), 'HTTP: '+json.dumps(obs['requests']), 'metadata:\n'+obs['metadata'].rstrip(), 'authority:\n'+str(obs['authority']), 'wake_queue:\n'+str(obs['wake_queue']), 'assertion failures: '+json.dumps(obs['failures']),''])
    (EVIDENCE/'live-cli-transcript.log').write_text('\n'.join(transcript)+'\n')
    shutil.rmtree(SCRATCH)
if any(r['result']=='fail' for r in results): sys.exit(1)
