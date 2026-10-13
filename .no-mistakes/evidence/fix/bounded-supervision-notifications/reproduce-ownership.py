import os, pathlib, subprocess, tempfile, re, json, shutil
root=pathlib.Path.cwd(); evidence=pathlib.Path(os.environ['FM_TEST_EVIDENCE_DIR'])
home=pathlib.Path(tempfile.mkdtemp(prefix='ownership-lab-',dir=root/'.validation-tmp'))
state=home/'state'; state.mkdir(); (home/'config').mkdir(); (home/'data').mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
env.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(state),FM_ROOT_OVERRIDE=str(root))
transcript=[]
def run(args,actor=None,expect=0,input=None):
    e=env.copy()
    if actor:e['FM_SUPERVISION_ACTOR']=actor
    p=subprocess.run(args,env=e,text=True,input=input,capture_output=True)
    transcript.append({'command':args,'actor':actor,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode==expect,(args,p.returncode,p.stderr)
    return p.stdout+p.stderr
def scope(flags=[]):
    out=run(['node','bin/fm-branch-dispatch.mjs','scope',*flags])
    return dict(line.split('=',1) for line in out.strip().splitlines())
def offer(text):
    out=run(['node','bin/fm-branch-dispatch.mjs','offer'],input=text+'\n')
    return dict(line.split('=',1) for line in out.strip().splitlines())
try:
    for task in ['old','fresh']:(state/(task+'.meta')).write_text('project='+str(home/'projects'/'probe')+'\nwindow=fm-'+task+'\n')
    rows=[f'1\t{i}\tsignal\t{"old" if i<=43 else "fresh"}.status\tsignal: event {i}\n' for i in range(1,92)]
    queue=''.join(rows); claim=''.join(str(i)+'\n' for i in range(1,44))
    (state/'.wake-queue').write_text(queue); (state/'.main-eligible-rows').write_text(claim)
    expected=' '.join(map(str,range(44,92)))
    for flags in [[],['--heartbeat'],['--afk'],['--heartbeat','--afk']]:
        s=scope(flags); assert s['rows']==expected and s['corrupted']=='0' and s['tasks']=='fresh',s
    run(['bash','bin/fm-wake-grant.sh','activate',str(os.getpid()),'ownership-proof'])
    run(['bash','bin/fm-wake-grant.sh','publish','ownership-proof',*map(str,range(1,92))],expect=3)
    assert not (state/'.branch-eligible-rows').exists()
    # Another main claim appears between scan and publication.
    (state/'.main-eligible-rows').write_text(claim+'44\n')
    run(['bash','bin/fm-wake-grant.sh','publish','ownership-proof',*map(str,range(44,92))],expect=3)
    fresh=scope()['rows'].split(); assert fresh==list(map(str,range(45,92)))
    run(['bash','bin/fm-wake-grant.sh','publish','ownership-proof',*fresh])
    assert (state/'.wake-queue').read_text()==queue
    drain=run(['bash','bin/fm-wake-drain.sh'],actor='branch')
    ack=re.search(r'WAKE_ACK_REQUIRED:.*--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',drain); assert ack,drain
    run(['bash','bin/fm-wake-drain.sh','--ack-through',ack[1],'--recovery-generation',ack[2]],actor='branch')
    assert (state/'.wake-queue').read_text()==''.join(rows[:44])
    assert (state/'.main-eligible-rows').read_text()==claim+'44\n'
    transcript.append({'persisted_result':{'main_rows_preserved':44,'branch_rows_acknowledged':47,'remaining_queue':(state/'.wake-queue').read_text()}})
    run(['bash','bin/fm-wake-grant.sh','release','ownership-proof'])
    (state/'.wake-queue').write_text(queue); (state/'.main-eligible-rows').write_text(claim)
    for bad in ['', '1\n1\n','not-a-sequence\n','1\n\n','1\r\n']:
        (state/'.main-eligible-rows').write_text(bad); assert scope()['corrupted']=='1'
        run(['bash','bin/fm-wake-grant.sh','publish','ownership-proof','44'],expect=1)
    (state/'.main-eligible-rows').unlink(); (state/'claim-target').write_text(claim)
    (state/'.main-eligible-rows').symlink_to(state/'claim-target'); assert scope()['corrupted']=='1'
    run(['bash','bin/fm-wake-grant.sh','publish','ownership-proof','44'],expect=1)
    (state/'.main-eligible-rows').unlink(); (state/'.main-eligible-rows').write_text(claim)
    (state/'.wake-queue').write_text(queue.replace('signal\told.status','invented\told.status',1)); assert scope()['corrupted']=='1'
    (state/'.wake-queue').write_text(queue.replace('old.status','missing.status',1)); assert scope()['corrupted']=='1'
    (state/'.wake-queue').write_text(queue.replace('signal: event 1\n','needs-decision: old.status\n',1))
    assert offer('signal: old.status fresh.status')['eligible']=='0'
    assert offer('signal: fresh.status')['eligible']=='1'
    assert (state/'.main-eligible-rows').read_text()==claim
    transcript.append({'persisted_result':{'claim_unchanged':True,'fresh_trigger_eligible':True,'old_decision_trigger_refused':True}})
    run(['bash','bin/fm-wake-grant.sh','deactivate',str(os.getpid()),'ownership-proof'])
    print('Actual dispatch, atomic grant, branch acknowledgement, corruption refusal, and decision precedence validated.')
finally:
    (evidence/'ownership-cli-transcript.json').write_text(json.dumps(transcript,indent=2))
    shutil.rmtree(home)
