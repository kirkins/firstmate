import os, sys, pathlib, subprocess, shlex, shutil, hashlib, json, tarfile
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/home/kirkins/.no-mistakes/evidence/01M4T32YT3CJB011SDSCDP8QGR')
LAB = ROOT / '.test-checksum-tmp' / 'runtime'

def run(argv, env=None):
    return subprocess.run(list(map(str, argv)), env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def executable(path, content):
    path.write_text(content)
    path.chmod(0o755)

# Disposable transport: run each real Firstmate-emitted command in a private
# filesystem, rather than contacting Docker Cloud. No product logic is replaced.
if len(sys.argv) > 1 and sys.argv[1] == '--sbx':
    args = sys.argv[2:]
    if args[0] == 'login':
        sys.stdin.read()
        sys.exit(0)
    assert args[:2] == ['--cloud', 'exec'] and args[3] == '--', args
    command = shlex.split(' '.join(args[4:]))
    case = pathlib.Path(os.environ['CHECKSUM_CASE'])
    with (case / 'payloads.log').open('a') as out:
        out.write(command[2] + '\n---\n')
    toolbin = case / 'toolbin'
    argv = ['bwrap', '--ro-bind', '/usr', '/usr', '--symlink', 'usr/bin', '/bin',
            '--symlink', 'usr/lib', '/lib', '--proc', '/proc', '--dev', '/dev',
            '--unshare-net', '--die-with-parent', '--bind', str(case / 'tmp'), '/tmp',
            '--bind', str(case / 'local'), '/usr/local', '--bind', str(case / 'workspace'), '/workspace',
            '--ro-bind', str(toolbin), '/tools', '--ro-bind', str(case / 'dist'), '/dist',
            '--ro-bind', str(LAB / 'repo'), '/repo', '--dir', '/home/lab',
            '--setenv', 'HOME', '/home/lab', '--setenv', 'PATH', '/usr/local/bin:/tools',
            '--setenv', 'FM_LINT_JOBS', '1', '--', '/usr/bin/bash', '-lc', command[2]]
    sys.exit(subprocess.call(argv))

LAB.mkdir(parents=True, exist_ok=True)
repo = LAB / 'repo'
repo.mkdir()
git_env = os.environ | {'GIT_CONFIG_GLOBAL':'/dev/null', 'GIT_CONFIG_NOSYSTEM':'1'}
for key in ('GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE'):
    git_env.pop(key, None)
assert run(['git', 'init', repo], git_env).returncode == 0
(repo / 'fixture.txt').write_text('disposable local clone fixture\n')
assert run(['git', '-C', repo, 'add', '.'], git_env).returncode == 0
assert run(['git', '-C', repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-m', 'fixture'], git_env).returncode == 0
repo_head = run(['git', '-C', repo, 'rev-parse', 'HEAD'], git_env).stdout.strip()
outer = LAB / 'outer-tools'
outer.mkdir()
executable(outer / 'sbx', '#!' + sys.executable + '\nimport runpy,sys\nsys.argv.insert(1,"--sbx")\nrunpy.run_path(' + repr(str(EVIDENCE / 'drive-checksum.py')) + ',run_name="__main__")\n')
executable(outer / 'kubectl', '#!/usr/bin/bash\nprintf cHJpdmF0ZS1maXh0dXJl\n')
arch = run(['uname', '-m']).stdout.strip()
name = 'node-v26.10.0-linux-' + arch + '.tar.xz'
archive_src = LAB / 'archive-src' / 'node-fixture'
(archive_src / 'bin').mkdir(parents=True)
# Link to the real existing Node26 binary only inside the disposable namespace;
# no Node binary is downloaded or installed.
(archive_src / 'bin' / 'node').symlink_to('/usr/bin/node')
(archive_src / 'proof.txt').write_text('real tar extracted this verified fixture archive\n')
archive = LAB / 'archive.tar.xz'
with tarfile.open(archive, 'w:xz') as tf:
    tf.add(archive_src, arcname='node-fixture')
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
base_bin = LAB / 'base-bin'
base_bin.mkdir()
(base_bin / 'fm-remote-hands.sh').write_text(run(['git','show','5ac8d3c279f8d22a0c0507a08dedabbc85feca76:bin/fm-remote-hands.sh']).stdout)
(base_bin / 'fm-remote-hands.sh').chmod(0o755)
shutil.copy(ROOT / 'bin/fm-env-lib.sh', base_bin)
results = []
with (EVIDENCE / 'runtime-checksum.log').open('w') as log:
    log.write('Real Firstmate prepare executable; private bwrap filesystem and network namespace; local distribution fixture via real curl file://; real SHA-256, tar, git, and existing Node26. Transport/credential adapters replace cloud dependencies; apt is disabled. No public downloads, package installation, credentials, or cloud workloads. FM_LINT_JOBS=1; parent address-space limit=4GiB.\n')
    for version, mode in [('target','good'),('target','wrong'),('target','missing'),('target','verifier-error'),('base','good'),('base','wrong')]:
        case = LAB / (version + '-' + mode)
        for child in ('tmp','local','workspace','toolbin','home','dist/latest-v26.x'):
            (case / child).mkdir(parents=True, exist_ok=True)
        dist = case / 'dist/latest-v26.x'
        shutil.copy(archive, dist / name)
        (dist / 'index.html').write_text(name + '\n')
        checksum = '' if mode == 'missing' else ('0'*64 if mode == 'wrong' else digest) + '  ' + name + '\n'
        (dist / 'SHASUMS256.txt').write_text(checksum)
        toolbin = case / 'toolbin'
        for tool in ('bash','env','sed','grep','head','uname','tar','xz','git','sha256sum','mkdir','dirname'):
            (toolbin / tool).symlink_to(shutil.which(tool))
        executable(toolbin / 'curl', '''#!/usr/bin/bash
args=()
for arg in "$@"; do
  case "$arg" in
    https://nodejs.org/dist/*) arg="file:///dist/${arg#https://nodejs.org/dist/}"; case "$arg" in */) arg="${arg}index.html";; esac ;;
  esac
  args+=("$arg")
done
exec /usr/bin/curl "${args[@]}"
''')
        executable(toolbin / 'sudo', '''#!/usr/bin/bash
if [ "$1" = apt-get ]; then printf 'package installation disabled in disposable verification\n' >&2; exit 0; fi
[ "$1" = tar ] || exit 90
exec "$@"
''')
        if mode == 'verifier-error':
            (toolbin / 'sha256sum').unlink()
            executable(toolbin / 'sha256sum', '#!/usr/bin/bash\nexit 9\n')
        env = git_env | {'PATH':str(outer)+':'+os.environ['PATH'], 'FM_HOME':str(case/'home'), 'FM_REMOTE_HANDS':'1', 'CHECKSUM_CASE':str(case), 'FM_LINT_JOBS':'1'}
        product = ROOT/'bin/fm-remote-hands.sh' if version == 'target' else base_bin/'fm-remote-hands.sh'
        command = [str(product),'prepare','--name','private-checksum-lab','--repo','file:///repo','--node-major','26','--dest','/workspace/checkout']
        proc = run(command, env)
        extracted = (case/'local/proof.txt').exists()
        cloned = (case/'workspace/checkout/.git').exists()
        node_version = run(['node','--version']).stdout.strip() if extracted else None
        download = case/'tmp/fm-node.tar.xz'
        record = {'version':version,'mode':mode,'exit':proc.returncode,'extracted':extracted,'cloned':cloned,'node_version':node_version,'archive_sha256':hashlib.sha256(download.read_bytes()).hexdigest() if download.exists() else None}
        log.write('\n' + json.dumps(record) + '\n$ ' + shlex.join(command) + '\nSTDOUT:\n' + proc.stdout + 'STDERR:\n' + proc.stderr)
        log.flush()
        if version == 'target':
            if mode == 'good':
                assert proc.returncode == 0 and extracted and cloned, record
                assert repo_head in proc.stdout and 'fm-node.tar.xz: OK' in proc.stdout and 'v26.10.0' in proc.stdout, proc.stdout
            else:
                assert proc.returncode != 0 and not extracted and not cloned, record
                assert 'node tarball checksum verification failed' in proc.stderr, proc.stderr
        else:
            assert proc.returncode == 0 and extracted and cloned, record
            assert 'node-v26.10.0-linux-' in proc.stderr and 'No such file' in proc.stderr, proc.stderr
        results.append(record)
    (EVIDENCE / 'runtime-results.json').write_text(json.dumps(results, indent=2)+'\n')
print(json.dumps(results, indent=2))
