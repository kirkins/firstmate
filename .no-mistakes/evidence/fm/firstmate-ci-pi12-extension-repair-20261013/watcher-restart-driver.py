import os, subprocess,time,json,shutil,threading
from pathlib import Path
root=Path.cwd();lab=root/'.validation-pi12/restart-home';evidence=Path('/home/kirkins/.no-mistakes/evidence/01M4TBQE5B5KJ6VF89TWMYKFS0')
subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],capture_output=True,check=True)
env=os.environ.copy()
for key in list(env):
 if key.startswith('FM_') or key in ['NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:env.pop(key,None)
env.update(FM_HOME=str(lab),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
(lab/'config/backlog-backend').write_text('manual\n');(lab/'state/.lock').write_text(str(os.getpid())+'\n')
(lab/'state/.last-check').touch();children=[];outputs=[];facts=[]
def alive(p):
 try:os.kill(p,0);return True
 except ProcessLookupError:return False
def wp():
 try:return int((lab/'state/.watch.lock/pid').read_text().strip())
 except (ValueError,FileNotFoundError):return None
def wait(fn,label):
 for _ in range(200):
  if fn():return
  time.sleep(.1)
 raise RuntimeError('timeout '+label+'; outputs='+repr(outputs))
def start(extra={}):
 output=[];outputs.append(output);p=subprocess.Popen(['bash','bin/fm-watch-arm.sh','--restart'],env={**env,**extra},stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);children.append(p)
 threading.Thread(target=lambda: output.extend(p.stdout),daemon=True).start()
 return p
try:
 first=start();wait(lambda:wp() is not None and any('beacon fresh' in x for x in outputs[0]),'first watcher')
 firstWatcher=wp();facts.append({'step':'first-arm','arm':first.pid,'watcher':firstWatcher,'output':list(outputs[0])})
 second=start({'FM_WATCH_PREDECESSOR_ARM_PID':str(first.pid)});wait(lambda:wp() is not None and wp()!=firstWatcher and any('beacon fresh' in x for x in outputs[1]),'replacement ready')
 secondWatcher=wp();wait(lambda:not alive(firstWatcher),'predecessor watcher retired')
 facts.append({'step':'restart','arm':second.pid,'watcher':secondWatcher,'predecessorWatcherAlive':alive(firstWatcher),'output':list(outputs[1])})
 (lab/'state/probe.status').write_text('done: live watcher restart notification\n')
 wait(lambda:second.poll() is not None,'replacement delivers fresh status')
 assert second.returncode==0,repr(outputs[1])
 assert any('signal:' in x and 'probe.status' in x for x in outputs[1]),repr(outputs[1])
 queue=(lab/'state/.wake-queue').read_text();assert 'probe.status' in queue,queue
 facts.append({'step':'fresh-status','exit':second.returncode,'output':list(outputs[1]),'durableQueue':queue})
 print(json.dumps(facts,indent=2))
finally:
 subprocess.run(['bash','bin/fm-watch-arm.sh','--stop'],env=env,capture_output=True)
 for p in children:
  if p.poll() is None:p.terminate()
  try:p.wait(timeout=10)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 (evidence/'watcher-restart.json').write_text(json.dumps(facts,indent=2))
 shutil.rmtree(lab)
