import errno
import hashlib
import json
import mmap
import os
from pathlib import Path
import resource
import shlex
import shutil
import subprocess

ROOT = Path.cwd()
LAB = ROOT / '.test-checksum-followup'
EVIDENCE = Path('/home/kirkins/.no-mistakes/evidence/01M4T32YT3CJB011SDSCDP8QGR')
CAP = 4294967296
HEAD = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
assert HEAD == '418ad36401d5dec117254d5d201eb8a635a7c126'
assert resource.getrlimit(resource.RLIMIT_AS) == (CAP, CAP)
assert os.environ['FM_LINT_JOBS'] == '1'
try:
    mmap.mmap(-1, CAP)
except OSError as exc:
    assert exc.errno == errno.ENOMEM
else:
    raise AssertionError('4GiB address-space allocation was not refused')

def run(args, env=None):
    return subprocess.run(args, text=True, capture_output=True, env=env)

slot_env = os.environ | {
    'XDG_STATE_HOME': str(LAB / 'slot-state'),
    'FM_STATE_OVERRIDE': str(LAB / 'slot-runtime'),
}
slot = [str(ROOT / 'bin/fm-heavy-slot.sh')]
status = run(slot + ['status'], slot_env)
competitor = run(slot + ['acquire', 'checksum-competitor', '--estimate', '4096'], slot_env)
assert status.returncode == 0 and 'task=checksum-followup' in status.stdout
assert competitor.returncode == 6
(EVIDENCE / 'followup-slot-and-cap.log').write_text(
    f'head={HEAD}\nRLIMIT_AS soft={CAP} hard={CAP}\n'
    '4GiB anonymous address-space allocation refused: ENOMEM\n'
    'FM_LINT_JOBS=1\nSequential scenario execution; isolated worktree slot\n'
    + status.stdout + competitor.stdout + competitor.stderr
)
print(f'RLIMIT_AS soft={CAP} hard={CAP}; allocation refused; FM_LINT_JOBS=1', flush=True)

old = LAB / 'old-installer.sh'
old.write_text(subprocess.check_output([
    'git', 'show', '5ac8d3c279f8d22a0c0507a08dedabbc85feca76:bin/fm-remote-hands.sh'
], text=True))
old.chmod(0o755)

tools = (
    'bash env sh sed tr cut grep head tail awk cat mv mktemp rm mkdir date sleep '
    'timeout dirname basename base64 chmod ln cp uname od ps stat find sort '
    'wc getconf readlink touch'
).split()
results = []
for name, reorder, old_installer in [
    ('portable-shasum', False, False),
    ('login-path-current', True, False),
    ('login-path-old-installer', True, True),
]:
    case = LAB / name
    for child in ('tools', 'tmp', 'fixture-tmp', 'home'):
        (case / child).mkdir(parents=True)
    toolbin = case / 'tools'
    for tool in tools:
        source = shutil.which(tool)
        assert source, f'missing PATH prerequisite: {tool}'
        (toolbin / tool).symlink_to(source)
    calls = case / 'sha-calls.log'
    copy_calls = case / 'copy-calls.log'
    login_calls = case / 'login-calls.log'
    (toolbin / 'shasum').write_text(
        '#!/usr/bin/bash\n'
        + 'printf "backend=/usr/bin/core_perl/shasum cwd=%s argv=" "$PWD" >> ' + shlex.quote(str(calls)) + '\n'
        + 'printf "%q " "$@" >> ' + shlex.quote(str(calls)) + '\n'
        + 'printf "\\n" >> ' + shlex.quote(str(calls)) + '\n'
        + 'exec /usr/bin/core_perl/shasum "$@"\n'
    )
    (toolbin / 'shasum').chmod(0o755)
    (toolbin / 'cp').unlink()
    (toolbin / 'cp').write_text(
        '#!/usr/bin/bash\n'
        + 'printf "%q " "$@" >> ' + shlex.quote(str(copy_calls)) + '\n'
        + 'printf "\\n" >> ' + shlex.quote(str(copy_calls)) + '\n'
        + 'exec /usr/bin/cp "$@"\n'
    )
    (toolbin / 'cp').chmod(0o755)
    profile = case / 'profile'
    profile.write_text(
        ('export PATH=/usr/bin:/usr/bin/core_perl:$PATH\n' if reorder else '')
        + 'printf "login pid=%s PATH=%s\\n" "$$" "$PATH" >> ' + shlex.quote(str(login_calls)) + '\n'
    )
    sentinel = case / 'tmp/fm-node.tar.xz'
    sentinel.write_bytes(b'pre-existing archive sentinel; never replace\n')
    digest_before = hashlib.sha256(sentinel.read_bytes()).hexdigest()
    command = [
        shutil.which('bwrap'), '--ro-bind', '/usr', '/usr',
        '--symlink', 'usr/bin', '/bin', '--symlink', 'usr/lib', '/lib',
        '--proc', '/proc', '--dev', '/dev', '--dir', '/etc',
        '--ro-bind', str(profile), '/etc/profile',
        '--ro-bind', str(ROOT), str(ROOT), '--bind', str(case), str(case),
        '--bind', str(case / 'tmp'), '/tmp',
        '--unshare-net', '--die-with-parent',
        '--setenv', 'HOME', str(case / 'home'),
        '--setenv', 'PATH', str(toolbin),
        '--setenv', 'TMPDIR', str(case / 'fixture-tmp'),
        '--setenv', 'FM_STATE_OVERRIDE', str(case / 'state'),
        '--setenv', 'XDG_STATE_HOME', str(case / 'xdg'),
        '--setenv', 'FM_LINT_JOBS', '1',
        '--setenv', 'GIT_CONFIG_GLOBAL', '/dev/null',
        '--setenv', 'GIT_CONFIG_NOSYSTEM', '1',
        '--chdir', str(ROOT),
    ]
    if old_installer:
        command += ['--ro-bind', str(old), str(ROOT / 'bin/fm-remote-hands.sh')]
    command += ['--', '/usr/bin/bash', '-c',
        'if command -v sha256sum; then exit 99; fi; '
        'printf "GNU sha256sum absent from initial test PATH; shasum=%s\\n" "$(command -v shasum)"; '
        'exec bash tests/fm-remote-hands.test.sh']
    proc = run(command)
    sha_log = calls.read_text() if calls.exists() else ''
    cp_log = copy_calls.read_text() if copy_calls.exists() else ''
    login_log = login_calls.read_text() if login_calls.exists() else ''
    remaining = [p.name for p in (case / 'fixture-tmp').iterdir()]
    record = {
        'name': name, 'head': HEAD,
        'production_installer': 'base' if old_installer else 'current',
        'native_execution': True,
        'exit_code': proc.returncode,
        'sha_backend': '/usr/bin/core_perl/shasum',
        'sha256sum_absent_initially': not (toolbin / 'sha256sum').exists(),
        'login_reordering': reorder,
        'sentinel_before': digest_before,
        'sentinel_after': hashlib.sha256(sentinel.read_bytes()).hexdigest(),
        'fixture_temp_remaining': remaining,
        'network': 'private namespace; no external connectivity',
        'cloud': 'disabled; test-owned sbx fixture executes production payloads locally',
        'node_host': 'v26.10.0; no installation',
        'memory_cap': list(resource.getrlimit(resource.RLIMIT_AS)),
        'FM_LINT_JOBS': os.environ['FM_LINT_JOBS'],
    }
    (EVIDENCE / ('followup-' + name + '.log')).write_text(
        json.dumps(record, indent=2) + '\nCommand:\n' + shlex.join(command)
        + '\nSTDOUT:\n' + proc.stdout + '\nSTDERR:\n' + proc.stderr
        + '\nReal SHA backend invocation records:\n' + sha_log
        + '\nActual archive copy invocation records:\n' + cp_log
        + '\nActual login initialization records:\n' + login_log
    )
    print(json.dumps(record), flush=True)
    assert record['sentinel_before'] == record['sentinel_after'], record
    assert not remaining, record
    assert 'backend=/usr/bin/core_perl/shasum' in sha_log, sha_log
    assert 'argv=-a 256 -c - ' in sha_log, sha_log
    assert '/download/fm-node.tar.xz' in cp_log, cp_log
    assert all(str(case / 'fixture-tmp') in line for line in cp_log.splitlines()), cp_log
    if reorder:
        assert 'PATH=/usr/bin:/usr/bin/core_perl:' in login_log, login_log
    if old_installer:
        assert proc.returncode == 1, proc.stderr
        assert 'not ok - missing checksum must fail prepare' in proc.stderr, proc.stderr
    else:
        assert proc.returncode == 0, proc.stderr
        assert 'prepare verifies the downloaded Node archive before extraction' in proc.stdout
    record['result'] = 'pass'
    results.append(record)

(EVIDENCE / 'followup-results.json').write_text(json.dumps(results, indent=2) + '\n')
print('PASS: portable SHA fallback, login PATH isolation, old-installer reproduction, sentinel preservation, EXIT cleanup', flush=True)
