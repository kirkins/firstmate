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
  if(session.isCompacting)throw Error('Isolated compaction provider failure');
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
    pi.on('session_before_compact',async(e)=>{events.push({type:'manual_compaction_held',reason:e.reason});await compactHeld;return undefined;});
    pi.on('session_compact_failed',e=>events.push({type:'session_compact_failed',reason:e.reason,aborted:e.aborted,errorMessage:e.errorMessage}));
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
const compacting=session.compact().then(()=>{throw Error('Unexpected successful compaction');},e=>({error:e.message}));
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
const compactFailure=await compacting;
const callbackQueue=queue;
const duringCompletion={sends:sends.length,pending:session.pendingMessageCount,isCompacting:false};
const afterManualCompact={pending:session.pendingMessageCount,userStarts:events.filter(e=>e.type==='user_message_start').length,agentSettlements:events.filter(e=>e.type==='agent_settled').length,isCompacting:session.isCompacting};
if(!events.some(e=>e.type==='session_compact_failed')||session.isCompacting)throw Error('Missing real compaction failure boundary');
const human=session.prompt('Hold one ordinary human turn for the fresh-notification proof.');
await waitFor(()=>completions===1&&session.isStreaming,'local human turn streaming');
const fullQueue=callbackQueue+'1\t3\tcheck\tB\tfresh notification B\n';
writeFileSync(`${home}/state/.wake-queue`,fullQueue);
writeFileSync(process.env.FM_PROOF_TRIGGER,'check: fresh notification B after manual compaction\n');
await waitFor(()=>armCount()===3,'B successor');await pause(300);
const afterFreshB={pending:session.pendingMessageCount,routineQueued:session.getFollowUpMessages().filter(t=>t.includes('FIRSTMATE WATCHER WAKE')).length,sendAttempts:sends.length,hasFreshDelivery:sends.some(s=>s.text.includes('notification B')),durableUnchanged:readFileSync(`${home}/state/.wake-queue`,'utf8')===fullQueue};
const result={sdk:'1.1.0',fixtureHome:home,atRejection,duringCompletion,afterManualCompact,afterFreshB,errors,sends,events};
if(atRejection.sends!==0 || atRejection.pending!==0 || duringCompletion.sends!==0 || afterManualCompact.userStarts!==0 || afterManualCompact.agentSettlements!==0 || afterFreshB.routineQueued!==1 || !afterFreshB.durableUnchanged)throw Error(`manual-compaction delivery regression: ${JSON.stringify(result)}`);
releaseResponse();await human;
await waitFor(()=>session.isIdle&&session.pendingMessageCount===0,'manual-compaction invitation consumed');
writeFileSync(`${process.env.FM_TEST_EVIDENCE_DIR}/compaction-failure-events.json`,JSON.stringify({mode:'failure',atRejection,afterManualCompact,afterFreshB,compactFailure,sends,events,errors,durableQueue:readFileSync(`${home}/state/.wake-queue`,'utf8')},null,2));
await session.exportToHtml(`${process.env.FM_TEST_EVIDENCE_DIR}/compaction-failure-session.html`);
await session.dispose();console.log('COMPACTION_FAILURE_OK');process.exit(0);
JS
status=$?
cat "$TMP_ROOT/manual-compaction-output"
exit "$status"
