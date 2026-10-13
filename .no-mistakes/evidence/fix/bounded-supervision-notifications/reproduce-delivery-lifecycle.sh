#!/usr/bin/env bash
set -u
. "/Users/philipkirkbride/.no-mistakes/worktrees/23fcc4135189/01M4T7GDD9T0QQZBJ8T889926Y/tests/lib.sh"
export NODE_NO_WARNINGS=1
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:?}
TMP_ROOT=$(fm_test_tmproot fm-delivery-proof)
proof_root=$ROOT
pi_pkg=$PI_PACKAGE_DIR
fixture="$TMP_ROOT/manual-compaction"
repo="$fixture/repo"
compact_home="$fixture/home"
agent_dir="$fixture/agent"
mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$repo/node_modules/@earendil-works" "$compact_home/state" "$compact_home/config" "$agent_dir" "$fixture/sessions"
cp "$proof_root/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
cp "$proof_root/.pi/extensions/lib/"*.ts "$repo/.pi/extensions/lib/"
cp "$proof_root/bin/fm-operational-input.sh" "$repo/bin/"
ln -s "$pi_pkg" "$repo/node_modules/@earendil-works/pi-coding-agent"
ln -s "$pi_pkg/node_modules/@earendil-works/pi-tui" "$repo/node_modules/@earendil-works/pi-tui"
ln -s "$pi_pkg/node_modules/typebox" "$repo/node_modules/typebox"
cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed=%s\n' "$2" >> "$FM_PROOF_ARM_LOG"
  exit 0
fi
printf 'arm=%s\n' "$$" >> "$FM_PROOF_ARM_LOG"
trap 'exit 0' TERM INT
printf 'watcher: started pid=%s recovery-generation=compact-proof\n' "$$"
while [ ! -e "$FM_PROOF_TRIGGER" ]; do sleep 0.02; done
reason=$(cat "$FM_PROOF_TRIGGER")
rm -f "$FM_PROOF_TRIGGER"
printf '%s\n' "$reason"
SH
chmod +x "$repo/bin/"*.sh
cat > "$agent_dir/models.json" <<'JSON'
{"providers":{"fm-compact-proof":{"baseUrl":"https://fm-compact-proof.invalid/v1","api":"openai-completions","models":[{"id":"local-model","name":"Local proof","contextWindow":8192,"maxTokens":512}]}}}
JSON
cat > "$agent_dir/auth.json" <<'JSON'
{"fm-compact-proof":{"type":"api_key","key":"placeholder-for-intercepted-local-proof"}}
JSON
FM_HOME="$compact_home" FM_ROOT_OVERRIDE="$repo" PI_CODING_AGENT_DIR="$agent_dir" FM_PI_PACKAGE_DIR="$pi_pkg" FM_PROOF_SESSIONS="$fixture/sessions" FM_PROOF_ARM_LOG="$fixture/arm.log" FM_PROOF_TRIGGER="$fixture/trigger" FM_WATCH_EXTENSION_LOG_KEEP_LINES=100 NODE_NO_WARNINGS=1 node --input-type=module > "$TMP_ROOT/manual-compaction-output" 2>&1 <<'JS'
import {existsSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const home=resolve(process.env.FM_HOME), agentDir=resolve(process.env.PI_CODING_AGENT_DIR);
writeFileSync(`${home}/state/.lock`,`${process.pid}\n`);
const {DefaultResourceLoader,ModelRegistry,ModelRuntime,SessionManager,SettingsManager,createAgentSession}=
  await import(pathToFileURL(`${process.env.FM_PI_PACKAGE_DIR}/dist/index.js`).href);
const events=[], sends=[], errors=[];
let releaseCompact,releaseCompletion,releaseResponse;
const completionHeld=new Promise(r=>releaseCompletion=r);
let probePi;
let releaseConstruction;
let constructionHeld=new Promise(r=>releaseConstruction=r);
let holdConstruction=false;
let holdSettlement=false,releaseSettlement;
const settlementHeld=new Promise(r=>releaseSettlement=r);
const compactHeld=new Promise(r=>releaseCompact=r);
const responseHeld=new Promise(r=>releaseResponse=r);
let completions=0;
const chunk=(delta,finish)=>`data: ${JSON.stringify({id:'local',object:'chat.completion.chunk',created:1,model:'local-model',choices:[{index:0,delta,finish_reason:finish}],...(finish?{usage:{prompt_tokens:1,completion_tokens:1,total_tokens:2}}:{})})}\n\n`;
globalThis.fetch=async(input)=>{
  const url=typeof input==='string'?input:input instanceof URL?input.href:input.url;
  if(!url.startsWith('https://fm-compact-proof.invalid/'))throw Error(`External traffic refused: ${url}`);
  completions++;
  const body=new ReadableStream({async start(c){const e=new TextEncoder();c.enqueue(e.encode(chunk({role:'assistant',content:'OK'},null)));if(completions===1)await responseHeld;c.enqueue(e.encode(chunk({},'stop')));c.enqueue(e.encode('data: [DONE]\n\n'));c.close();}});
  return new Response(body,{status:200,headers:{'content-type':'text/event-stream'}});
};
writeFileSync(`${agentDir}/settings.json`,JSON.stringify({compaction:{enabled:false,keepRecentTokens:1,reserveTokens:32},retry:{enabled:false}}));
const settings=SettingsManager.create(process.env.FM_ROOT_OVERRIDE,agentDir);
const watcher=(await import(pathToFileURL(`${process.env.FM_ROOT_OVERRIDE}/.pi/extensions/fm-primary-pi-watch.ts`).href)).default;
const loader=new DefaultResourceLoader({cwd:process.env.FM_ROOT_OVERRIDE,agentDir,settingsManager:settings,
  extensionFactories:[{name:'settlement-hold-proof',factory:(pi)=>{
    pi.on('agent_settled',async e=>{if(holdSettlement){events.push({type:'held_settlement',aborted:e.aborted});await settlementHeld;}});
  }},{name:'watcher-under-proof',factory:(pi)=>{
    const nativeSend=pi.sendUserMessage.bind(pi);
    pi.sendUserMessage=(content,options)=>{const value=nativeSend(content,options);sends.push({text:content,returnType:typeof value});return value;};
    watcher(pi);
  }},{name:'manual-compaction-proof',factory:(pi)=>{
    probePi=pi;
    pi.on('session_before_compact',async(e)=>{events.push({type:'manual_compaction_held',reason:e.reason});await compactHeld;return {compaction:{summary:'Local manual compaction proof summary',firstKeptEntryId:e.preparation.firstKeptEntryId,tokensBefore:e.preparation.tokensBefore}};});
    pi.on('session_compact',async e=>{events.push({type:'session_compact',reason:e.reason});await completionHeld;});
    pi.on('input',e=>events.push({type:'input',source:e.source,text:e.text}));
    pi.on('before_agent_start',async e=>{events.push({type:'before_agent_start',text:e.prompt});if(holdConstruction)await constructionHeld;});
    pi.on('message_start',e=>{if(e.message.role==='user')events.push({type:'user_message_start',text:e.message.content.filter(x=>x.type==='text').map(x=>x.text).join('\n')});});
    pi.on('agent_settled',e=>events.push({type:'agent_settled',aborted:e.aborted}));
  }}],noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,noContextFiles:true});
await loader.reload();
const runtime=await ModelRuntime.create({authPath:`${agentDir}/auth.json`,modelsPath:`${agentDir}/models.json`});
const registry=new ModelRegistry(runtime);await registry.refresh();
const model=registry.find('fm-compact-proof','local-model');if(!model)throw Error('Local fake model unresolved');
const manager=SessionManager.create(process.env.FM_ROOT_OVERRIDE,process.env.FM_PROOF_SESSIONS);
for(let n=0;n<4;n++){
  manager.appendMessage({role:'user',content:[{type:'text',text:`Seeded user turn ${n} `.repeat(100)}],timestamp:Date.now()});
  manager.appendMessage({role:'assistant',content:[{type:'text',text:`Seeded assistant reply ${n} `.repeat(100)}],api:'openai-completions',provider:model.provider,model:model.id,usage:{input:1,output:1,cacheRead:0,cacheWrite:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:'stop',timestamp:Date.now()});
}
const {session}=await createAgentSession({cwd:process.env.FM_ROOT_OVERRIDE,sessionManager:manager,settingsManager:settings,resourceLoader:loader,modelRuntime:runtime,model,noTools:'builtin'});
await session.bindExtensions({onError:e=>errors.push({event:e.event,error:e.error})});
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function waitFor(fn,label){for(let n=0;n<250;n++){if(fn())return;await pause(20);}throw Error(`Timeout ${label}; events=${JSON.stringify(events)}; sends=${JSON.stringify(sends)}; errors=${JSON.stringify(errors)}`);}
const armCount=()=>existsSync(process.env.FM_PROOF_ARM_LOG)?readFileSync(process.env.FM_PROOF_ARM_LOG,'utf8').split('\n').filter(x=>x.startsWith('arm=')).length:0;
await waitFor(()=>armCount()===1,'initial watcher');
const compacting=session.compact();
await waitFor(()=>events.some(e=>e.type==='manual_compaction_held')&&session.isCompacting,'manual compaction held');
const queue='1\t1\tcheck\tA\tmanual-compaction notification A\n';
writeFileSync(`${home}/state/.wake-queue`,queue);
writeFileSync(process.env.FM_PROOF_TRIGGER,'check: notification A during manual compaction\n');
await waitFor(()=>armCount()===2,'A successor during manual compaction');
await pause(100);
const nativeReturn=probePi.sendUserMessage('Direct local SDK preflight rejection probe.');
await waitFor(()=>errors.some(e=>e.event==='send_user_message'&&e.error.includes('compaction')),'direct vendor rejection during manual compaction');
const atRejection={sends:sends.length,returnType:typeof nativeReturn,pending:session.pendingMessageCount,userStarts:events.filter(e=>e.type==='user_message_start').length,agentSettlements:events.filter(e=>e.type==='agent_settled').length};
releaseCompact();
await waitFor(()=>events.some(e=>e.type==='session_compact')&&session.isCompacting,'held successful completion boundary');
const callbackQueue=queue+'1\t2\tcheck\tcompletion\tcompletion-boundary notification\n';
writeFileSync(`${home}/state/.wake-queue`,callbackQueue);
writeFileSync(process.env.FM_PROOF_TRIGGER,'check: notification inside manual compaction completion hook\n');
await waitFor(()=>armCount()===3,'completion-hook successor');await pause(100);
const duringCompletion={sends:sends.length,pending:session.pendingMessageCount,isCompacting:session.isCompacting};
releaseCompletion();await compacting;
const afterManualCompact={pending:session.pendingMessageCount,userStarts:events.filter(e=>e.type==='user_message_start').length,agentSettlements:events.filter(e=>e.type==='agent_settled').length,isCompacting:session.isCompacting};
const human=session.prompt('Hold one ordinary human turn for the fresh-notification proof.');
await waitFor(()=>completions===1&&session.isStreaming,'local human turn streaming');
const fullQueue=callbackQueue+'1\t3\tcheck\tB\tfresh notification B\n';
writeFileSync(`${home}/state/.wake-queue`,fullQueue);
writeFileSync(process.env.FM_PROOF_TRIGGER,'check: fresh notification B after manual compaction\n');
await waitFor(()=>armCount()===4,'B successor');await pause(300);
const afterFreshB={pending:session.pendingMessageCount,routineQueued:session.getFollowUpMessages().filter(t=>t.includes('FIRSTMATE WATCHER WAKE')).length,sendAttempts:sends.length,hasFreshDelivery:sends.some(s=>s.text.includes('notification B')),durableUnchanged:readFileSync(`${home}/state/.wake-queue`,'utf8')===fullQueue};
const result={sdk:'1.1.0',fixtureHome:home,atRejection,duringCompletion,afterManualCompact,afterFreshB,errors,sends,events};
if(atRejection.sends!==0 || atRejection.pending!==0 || duringCompletion.sends!==0 || !duringCompletion.isCompacting || afterManualCompact.userStarts!==0 || afterManualCompact.agentSettlements!==0 || afterFreshB.routineQueued!==1 || !afterFreshB.durableUnchanged)throw Error(`manual-compaction delivery regression: ${JSON.stringify(result)}`);
releaseResponse();await human;
await waitFor(()=>session.isIdle&&session.pendingMessageCount===0,'manual-compaction invitation consumed');
const baseline={sends:sends.length,userStarts:events.filter(e=>e.type==='user_message_start').length,settlements:events.filter(e=>e.type==='agent_settled').length,completions};
await runtime.logout(model.provider);
if(registry.hasConfiguredAuth(model)||await runtime.checkAuth(model.provider))throw Error('Logout retained local placeholder credentials');
const credentialQueue=fullQueue+'1\t4\tcheck\tcredential-A\tcredential notification A\n';
writeFileSync(`${home}/state/.wake-queue`,credentialQueue);
writeFileSync(process.env.FM_PROOF_TRIGGER,'check: credential notification A while logged out\n');
await waitFor(()=>armCount()===5,'logged-out A successor');await pause(200);
const credentialReturn=probePi.sendUserMessage('Direct local SDK credential rejection probe.');
await waitFor(()=>errors.some(e=>e.event==='send_user_message'&&e.error.includes('No API key')),'direct vendor credential rejection');
if(typeof credentialReturn!=='undefined'||session.pendingMessageCount!==0||events.filter(e=>e.type==='user_message_start').length!==baseline.userStarts||events.filter(e=>e.type==='agent_settled').length!==baseline.settlements||completions!==baseline.completions)throw Error(`Credential rejection unexpectedly queued or started a run: ${JSON.stringify({sends,events,errors})}`);
const rejectedSends=sends.length;
await runtime.login(model.provider,'api_key',{prompt:async()=> 'placeholder-for-intercepted-local-proof',notify() {}});
if(!registry.hasConfiguredAuth(model))throw Error('Login failed to restore local placeholder credentials');
if(events.filter(e=>e.type==='user_message_start').length!==baseline.userStarts||events.filter(e=>e.type==='agent_settled').length!==baseline.settlements)throw Error('Credential recovery unexpectedly started or settled a run');
holdConstruction=true;
const freshQueue=credentialQueue+'1\t5\tcheck\tcredential-B\tfresh credential notification B\n';
writeFileSync(`${home}/state/.wake-queue`,freshQueue);
writeFileSync(process.env.FM_PROOF_TRIGGER,'check: fresh credential notification B after login\n');
await waitFor(()=>armCount()===6&&events.some(e=>e.type==='before_agent_start'&&e.text.includes('credential notification A')),'fresh close restoring idle A construction');
if(session.pendingMessageCount!==0||sends.length!==rejectedSends+1)throw Error('Recovered idle invitation was not constructing outside the pending queue');
const constructionQueue=freshQueue+'1\t6\tcheck\tcredential-C\tcredential construction notification C\n';
writeFileSync(`${home}/state/.wake-queue`,constructionQueue);
writeFileSync(process.env.FM_PROOF_TRIGGER,'check: credential notification C during idle construction\n');
await waitFor(()=>armCount()===7,'successor during idle construction');await pause(200);
if(sends.length!==rejectedSends+1||session.pendingMessageCount!==0||events.filter(e=>e.type==='user_message_start').length!==baseline.userStarts||readFileSync(`${home}/state/.wake-queue`,'utf8')!==constructionQueue)throw Error('Empty pending queue released an in-flight idle invitation or changed durable rows');
holdConstruction=false;releaseConstruction();
await waitFor(()=>events.some(e=>e.type==='user_message_start'&&e.text.includes('credential notification A'))&&session.isIdle,'exact recovered A consumption');
const consumedQueue=constructionQueue+'1\t7\tcheck\tcredential-D\tcredential notification D\n';
writeFileSync(`${home}/state/.wake-queue`,consumedQueue);
writeFileSync(process.env.FM_PROOF_TRIGGER,'check: credential notification D after consumption\n');
await waitFor(()=>armCount()===8&&events.some(e=>e.type==='user_message_start'&&e.text.includes('credential notification D'))&&session.isIdle,'new delivery after exact consumption');
if(sends.length!==rejectedSends+2||session.pendingMessageCount!==0||readFileSync(`${home}/state/.wake-queue`,'utf8')!==consumedQueue)throw Error('Credential recovery lost bounded delivery or durable events');
holdSettlement=true;
const settling=session.prompt('Ordinary human turn before held settlement.');
await waitFor(()=>events.some(e=>e.type==='held_settlement'),'asynchronous settlement before watcher handler');
const settlementSends=sends.length;
const settlementQueue=consumedQueue+'1\t8\tcheck\tsettlement-A\tsettlement notification A\n';
writeFileSync(`${home}/state/.wake-queue`,settlementQueue);
writeFileSync(process.env.FM_PROOF_TRIGGER,'check: settlement notification A\n');
await waitFor(()=>armCount()===9&&sends.length===settlementSends+1,'main-only A offered during held settlement');
await pause(100);
if(!session.isIdle||session.pendingMessageCount!==0||events.some(e=>e.type==='before_agent_start'&&e.text.includes('settlement notification A'))||events.some(e=>e.type==='user_message_start'&&e.text.includes('settlement notification A')))throw Error('Settlement did not defer A outside the public queue');
constructionHeld=new Promise(r=>releaseConstruction=r);
holdConstruction=true;
holdSettlement=false;releaseSettlement();
await waitFor(()=>events.some(e=>e.type==='before_agent_start'&&e.text.includes('settlement notification A')),'original deferred A constructing');
await pause(200);
if(sends.length!==settlementSends+1||session.pendingMessageCount!==0)throw Error(`Settlement replay duplicated an in-flight invitation: ${JSON.stringify({sends,events})}`);
holdConstruction=false;releaseConstruction();await settling;
await waitFor(()=>session.isIdle&&events.some(e=>e.type==='user_message_start'&&e.text.includes('settlement notification A')),'original settlement invitation consumed');
if(sends.length!==settlementSends+1||events.filter(e=>e.type==='user_message_start'&&e.text.includes('settlement notification A')).length!==1||readFileSync(`${home}/state/.wake-queue`,'utf8')!==settlementQueue)throw Error('Settlement delivered A more than once or changed durable work');
const final={sdk:'1.1.0',head:process.env.FM_TEST_HEAD,atRejection,duringCompletion,afterManualCompact,afterFreshB,credentialRecovery:{rejectedSends,recoveredSends:2},settlement:{offers:sends.length-settlementSends,userStarts:events.filter(e=>e.type==='user_message_start'&&e.text.includes('settlement notification A')).length},durableQueue:readFileSync(`${home}/state/.wake-queue`,'utf8'),events,sends,errors};
writeFileSync(`${process.env.FM_TEST_EVIDENCE_DIR}/delivery-lifecycle-events.json`,JSON.stringify(final,null,2));
await session.exportToHtml(`${process.env.FM_TEST_EVIDENCE_DIR}/delivery-lifecycle-session.html`);
await session.dispose();console.log("MANUAL_COMPACT_CREDENTIAL_AND_SETTLEMENT_OK");process.exit(0);
JS
status=$?
cat "$TMP_ROOT/manual-compaction-output"
exit "$status"
