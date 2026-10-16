(()=>{
"use strict";
const targets=new Set(["transfers","transfer_slot_statuses","docks"]);
const cache=new Map(),pins=new Map(),interaction=new Map(),stats={saves:[],sync:[],connections:new Map()};
let client=null,dialog=null,historyBefore=null,historyRows=[];
let featureAccess={role:null,permissions:{}},signedInUser=null;
const metricDialogs=new Set();
const canFeature=key=>featureAccess.role==="Owner"||featureAccess.permissions?.[key]===true;
function applyFeatureControls(){
 document.querySelectorAll("[data-edit-history-control]").forEach(n=>n.hidden=!canFeature("edit_history"));
 document.querySelectorAll("[data-live-connection-control]").forEach(n=>n.hidden=!canFeature("live_connection"));
 if(!canFeature("edit_history")&&dialog?.open)dialog.close();
 if(!canFeature("live_connection"))for(const d of metricDialogs)if(d.open)d.close();
}
const key=(t,id)=>t+":"+id;
function remember(table,rows){for(const row of Array.isArray(rows)?rows:[rows])if(row?.id&&row.edit_revision!=null){const k=key(table,row.id),old=cache.get(k);if(!old||Number(row.edit_revision)>=Number(old.edit_revision))cache.set(k,{...old,...row});}}
const ownVersions=new Map();
let writeTail=Promise.resolve();
function enqueueWrite(task){const result=writeTail.then(task,task);writeTail=result.catch(()=>{});return result;}
function acceptOwn(table,rows){
 remember(table,rows);
 for(const row of Array.isArray(rows)?rows:[rows]){
  if(!row?.id||row.edit_revision==null)continue;
  const k=key(table,row.id),rev=Number(row.edit_revision),prior=ownVersions.get(k);
  if(!prior||rev>prior.to)ownVersions.set(k,{from:prior&&prior.to===rev-1?prior.from:rev-1,to:rev});
  const known=cache.get(k);
  if(Number(known?.edit_revision)!==rev)continue;
  if(pins.has(k))pins.set(k,{...row});
  if(interaction.has(k))interaction.set(k,{...row});
 }
}
function rebaseOwn(expected,table){
 const result={...expected};
 for(const [id,value] of Object.entries(result)){
  const k=table?key(table,id):id,own=ownVersions.get(k),known=cache.get(k);
  if(own&&Number(value)>=own.from&&Number(value)<=own.to&&Number(known?.edit_revision)===own.to)result[id]=own.to;
 }
 return result;
}
function showConflict(table,current,patch){
 const d=document.createElement("dialog");d.className="edit-review";
 const h=document.createElement("h2");h.textContent="This record changed";
 const p=document.createElement("p");p.textContent="Your save was not applied. Your attempted changes are recorded in Edit history. Review the latest version before saving again.";
 const before=document.createElement("pre");before.textContent="Your requested changes\n"+JSON.stringify(patch,null,2)+"\n\nCurrent saved version\n"+JSON.stringify(current,null,2);
 const keep=document.createElement("button");keep.textContent="Keep my draft";keep.onclick=()=>d.close();
 const latest=document.createElement("button");latest.textContent="Load latest version";latest.onclick=()=>{
  Object.values(current||{}).forEach(row=>{pins.delete(key(table,row.id));remember(table,row)});
  const detail={table,rows:Object.values(current||{}),handled:false};
  document.dispatchEvent(new CustomEvent("edit-load-latest",{detail}));d.close();
  if(!detail.handled)window.location.reload();
 };
 d.append(h,p,before,keep,latest);document.body.append(d);d.addEventListener("close",()=>d.remove(),{once:true});d.showModal();
}
function mutation(sb,table,patch,operation){
 let ids=[],single=false,selected=false,invalid=false,promise;
 const expected={};
 function capture(values){ids=values.map(String);for(const id of ids){const row=pins.get(key(table,id))||interaction.get(key(table,id))||cache.get(key(table,id));if(row?.edit_revision!=null)expected[id]=row.edit_revision;}}
 const chain={
  eq(column,value){if(column==="id")capture([value]);else invalid=true;return chain},
  in(column,values){if(column==="id")capture(values);else invalid=true;return chain},
  select(){selected=true;return chain},single(){single=true;selected=true;return chain},maybeSingle(){single=true;selected=true;return chain},
  then(resolve,reject){
   if(!promise)promise=(async()=>{
    if(invalid||!ids.length)return {data:null,error:{message:"This edit needs a specific record. Reload and try again.",code:"EDIT_FILTER"}};
    const start=performance.now();
    const r=await sb.rpc("guarded_edit",{p_table:table,p_ids:ids,p_expected:expected,p_patch:patch||{},p_operation:operation});
    stats.saves.push(performance.now()-start);if(stats.saves.length>100)stats.saves.shift();
    if(r.error)return r;
    if(!r.data?.ok){
     if(r.data?.conflict){Object.values(r.data.current||{}).forEach(row=>remember(table,row));showConflict(table,r.data.current,patch);}
     return {data:null,error:{message:r.data?.message||"Edit not applied.",code:r.data?.conflict?"EDIT_CONFLICT":"EDIT_REJECTED"}};
    }
    acceptOwn(table,r.data.rows);
    return {data:selected?(single?r.data.rows?.[0]||null:r.data.rows):null,error:null};
   })();
   return promise.then(resolve,reject);
  }
 };
 return chain;
}
function wrapBuilder(builder,table){
 return new Proxy(builder,{get(target,prop){
  if(prop==="update")return patch=>mutation(clientFor(target),table,patch,"update");
  if(prop==="delete")return ()=>mutation(clientFor(target),table,{},"delete");
  if(prop==="then")return (resolve,reject)=>target.then(r=>{if(!r.error)remember(table,r.data);return resolve?resolve(r):r},reject);
  const value=Reflect.get(target,prop,target);
  return typeof value==="function"? (...args)=>{const result=value.apply(target,args);return result&&typeof result.then==="function"?wrapBuilderWithClient(result,table,builderClients.get(target)):result}:value;
 }});
}
const builderClients=new WeakMap();
const clientFor=builder=>builderClients.get(builder);
function wrapBuilderWithClient(builder,table,sb){builderClients.set(builder,sb);return wrapBuilder(builder,table)}
const originalCreate=window.supabase.createClient;
window.supabase={...window.supabase,createClient(...args){
 const sb=originalCreate(...args);if(!client){client=sb;sb.auth.onAuthStateChange((_event,session)=>{
 const next=session?.user?.id||null;
 if(!next||next!==signedInUser){ownVersions.clear();pins.clear();interaction.clear();signedInUser=next;featureAccess={role:null,permissions:{}};applyFeatureControls();}
 });}
 const from=sb.from.bind(sb),channel=sb.channel.bind(sb),rpc=sb.rpc.bind(sb);
 const guardedActions=new Set(["set_docks_hidden","assign_dock_trailer","release_dock_trailer","complete_seal_check","respond_dock_activity","save_dock_details"]);
 const processRpc=async(name,args,...rest)=>{
  if(name==="guarded_edit"){
   const r=await rpc(name,{...args,p_expected:rebaseOwn(args.p_expected,args.p_table)},...rest);
   if(!r.error&&r.data?.ok)acceptOwn(args.p_table,r.data.rows);
   return r;
  }
  if(name==="get_dock_access"||name==="get_transfer_access"){
   const r=await rpc(name,args,...rest);
   featureAccess=r.error?{role:null,permissions:{}}:{role:r.data?.role||null,permissions:r.data?.permissions||{}};
   applyFeatureControls();return r;
  }
  if(name==="save_summary_record"&&!args.p_deleted){
   const table=args.p_type==="Job"?"transfers":"transfer_slot_statuses",k=key(table,args.p_id),row=pins.get(k)||cache.get(k);
   const r=await rpc("guarded_summary_edit",{p_args:args,p_expected:row?.edit_revision??null});
   if(r.error)return r;
   if(!r.data?.ok){
    if(r.data?.conflict){Object.values(r.data.current||{}).forEach(row=>remember(table,row));showConflict(table,r.data.current,args);}
    return {data:null,error:{message:r.data?.message||"Report edit not applied.",code:r.data?.conflict?"EDIT_CONFLICT":"EDIT_REJECTED"}};
   }
   acceptOwn(table,r.data.row);return {data:r.data.result,error:null};
  }
  if(["move_board_link_group","resize_board_link_group"].includes(name)){
   const expected={};for(const [k,row] of cache){const baseline=pins.get(k)||interaction.get(k)||row;if(baseline.edit_revision!=null)expected[k]=baseline.edit_revision;}
   const started=performance.now(),r=await rpc("guarded_board_action",{p_action:name,p_args:args,p_expected:rebaseOwn(expected,null)});
   stats.saves.push(performance.now()-started);if(stats.saves.length>100)stats.saves.shift();
   if(r.error)return r;
   if(!r.data?.ok){
    if(r.data?.conflict){
     const byTable={};for(const [k,row] of Object.entries(r.data.current||{})){const table=k.split(":")[0];remember(table,row);(byTable[table]??={})[row.id]=row;}
     const table=Object.keys(byTable)[0];if(table)showConflict(table,byTable[table],args);
    }
    return {data:null,error:{message:r.data?.message||"Board action not applied.",code:r.data?.conflict?"EDIT_CONFLICT":"EDIT_REJECTED"}};
   }
   acceptOwn("transfers",r.data.result?.jobs||[]);acceptOwn("transfer_slot_statuses",r.data.result?.statuses||[]);
   return {data:r.data.result,error:null};
  }
  if(!guardedActions.has(name))return rpc(name,args,...rest);
  const expected={};
  for(const [k,row] of cache)if(k.startsWith("docks:")){const baseline=pins.get(k)||interaction.get(k)||row;if(baseline.edit_revision!=null)expected[row.id]=baseline.edit_revision;}
  const started=performance.now(),r=await rpc("guarded_dock_action",{p_action:name,p_args:args,p_expected:expected});
  stats.saves.push(performance.now()-started);if(stats.saves.length>100)stats.saves.shift();
  if(r.error)return r;
  if(!r.data?.ok){
   if(r.data?.conflict){Object.values(r.data.current||{}).forEach(row=>remember("docks",row));showConflict("docks",r.data.current,args);}
   return {data:null,error:{message:r.data?.message||"Dock action not applied.",code:r.data?.conflict?"EDIT_CONFLICT":"EDIT_REJECTED"}};
  }
  acceptOwn("docks",r.data.rows);
  for(const row of r.data.rows||[])if(pins.has(key("docks",row.id)))pins.set(key("docks",row.id),row);
  return {data:r.data.result,error:null};
 };
 const writeActions=new Set(["guarded_edit","save_summary_record","move_board_link_group","resize_board_link_group",...guardedActions]);
 sb.rpc=(name,args,...rest)=>writeActions.has(name)?enqueueWrite(()=>processRpc(name,args,...rest)):processRpc(name,args,...rest);
 sb.from=table=>targets.has(table)?wrapBuilderWithClient(from(table),table,sb):from(table);
 sb.channel=(...args)=>{
  const ch=channel(...args),on=ch.on.bind(ch),subscribe=ch.subscribe.bind(ch);
  ch.on=(kind,filter,callback)=>on(kind,filter,payload=>{
   if(kind==="postgres_changes"&&targets.has(filter.table)){
    if(payload.eventType!=="DELETE")remember(filter.table,payload.new);
    if(payload.commit_timestamp){const estimated=Date.now()-Date.parse(payload.commit_timestamp);if(estimated>=0&&estimated<60000){stats.sync.push(estimated);if(stats.sync.length>100)stats.sync.shift();}}
   }return callback(payload);
  });
  ch.subscribe=(callback,...rest)=>subscribe((status,...other)=>{stats.connections.set(String(args[0]),status);callback?.(status,...other)},...rest);
  return ch;
 };return sb;
}};
window.EditGuard={
 pin(table,row){if(!row?.id)return;const k=key(table,row.id),known=cache.get(k);pins.set(k,{...known,...row,edit_revision:row.edit_revision??known?.edit_revision});},
 unpin(table,id){if(id)pins.delete(key(table,id));else for(const k of pins.keys())if(k.startsWith(table+":"))pins.delete(k);},
 remember,stats,latest:(table,id)=>cache.get(key(table,id))
};
function readable(row){
 const r=row.current_record||{};
 return row.table_name==="docks"?"Building "+r.building+" · Dock "+r.dock_number:
 row.table_name==="transfers"?"Move #"+(r.move_number??"—"):r.driver+" · "+(r.status||"Time slot");
}
function renderHistory(){
 const body=dialog.querySelector("[data-history]");
 body.replaceChildren(...historyRows.map(row=>{
  const article=document.createElement("article"),title=document.createElement("strong"),meta=document.createElement("div"),details=document.createElement("pre");
  title.textContent=readable(row)+" · "+row.operation+" · "+row.outcome.toUpperCase();
  meta.textContent=new Date(row.attempted_at).toLocaleString()+" · "+row.actor_name;
  details.textContent=JSON.stringify(row.requested,null,2)+(row.reason?"\n"+row.reason:"");
  article.append(title,meta,details);return article;
 }));
}
async function loadHistory(reset=false){
 if(!canFeature("edit_history"))return;
 if(reset){historyBefore=null;historyRows=[]}
 const status=dialog.querySelector("[data-history-status]");status.textContent="Loading…";
 let q=client.from("edit_attempts").select("*").order("id",{ascending:false}).limit(50);
 if(historyBefore)q=q.lt("id",historyBefore);
 const r=await q;
 if(r.error){status.textContent=r.error.message;return}
 historyRows.push(...r.data);historyBefore=r.data.at(-1)?.id||historyBefore;renderHistory();status.textContent=r.data.length===50?"":"No more entries.";
 dialog.querySelector("[data-older]").disabled=r.data.length<50;
}
function openHistory(){
 if(!client||!canFeature("edit_history"))return;
 if(!dialog){
  dialog=document.createElement("dialog");dialog.className="edit-review";
  dialog.innerHTML='<h2>Edit history</h2><p>Applied changes, conflicts, and rejected submissions. Recording begins when this feature was enabled.</p><button type="button" data-refresh>Refresh</button><button type="button" data-close>Close</button><div data-history-status></div><div data-history></div><button type="button" data-older>Load older</button>';
  dialog.querySelector("[data-close]").onclick=()=>dialog.close();
  dialog.querySelector("[data-refresh]").onclick=()=>loadHistory(true);
  dialog.querySelector("[data-older]").onclick=()=>loadHistory();
  document.body.append(dialog);
 }
 dialog.showModal();loadHistory(true);
}
function openMetrics(){
 if(!canFeature("live_connection"))return;
 const d=document.createElement("dialog");d.className="edit-review";
 const h=document.createElement("h2");h.textContent="Live connection";
 const p=document.createElement("p"),mean=a=>a.length?Math.round(a.reduce((x,y)=>x+y,0)/a.length)+" ms":"No samples yet";
 p.style.whiteSpace="pre-wrap";p.textContent="Average save round trip: "+mean(stats.saves)+"\nAverage server-to-browser event delay (estimated): "+mean(stats.sync)+"\n\n"+[...stats.connections].map(([name,status])=>name+": "+status).join("\n")+"\n\nEvent delay depends on computer clock accuracy and excludes the sender's save time. These are samples from this tab.";
 const close=document.createElement("button");close.textContent="Close";close.onclick=()=>d.close();d.append(h,p,close);document.body.append(d);metricDialogs.add(d);d.onclose=()=>{metricDialogs.delete(d);d.remove()};d.showModal();
}
function beginInteraction(event){
 if(!event.target.closest?.(".card,.slot-status-block,.dock-button,.dock-hidden-bar,.dock-trailer-target"))return;
 interaction.clear();for(const [k,row] of cache)interaction.set(k,{...row});
}
document.addEventListener("pointerdown",beginInteraction,true);
document.addEventListener("dragstart",beginInteraction,true);
for(const type of ["pointerup","pointercancel","dragend"])document.addEventListener(type,()=>setTimeout(()=>interaction.clear(),0),true);
document.addEventListener("DOMContentLoaded",()=>{
 const style=document.createElement("style");style.textContent='.edit-review{width:min(880px,94vw);max-height:85vh;overflow:auto;border:1px solid var(--border,var(--line,#64748b));border-radius:14px;padding:20px;background:var(--panel,#fff);color:var(--text,#17212b)}.edit-review::backdrop{background:#0009}.edit-review pre{white-space:pre-wrap;overflow-wrap:break-word;font:12px/1.5 monospace}.edit-review button{margin:5px;padding:7px 12px}.edit-review article{border-bottom:1px solid #8886;padding:12px 0}.edit-review article div{font-size:12px;opacity:.8}';document.head.append(style);
 const exportButton=document.getElementById("exportCsv");
 if(!exportButton)return;
 const history=document.createElement("button");history.type="button";history.className="secondary small";history.textContent="Edit history";history.dataset.editHistoryControl="";history.dataset.permission="edit_history";history.hidden=true;history.onclick=openHistory;
 const metrics=history.cloneNode();delete metrics.dataset.editHistoryControl;metrics.dataset.liveConnectionControl="";metrics.dataset.permission="live_connection";metrics.textContent="Live connection";metrics.onclick=openMetrics;exportButton.after(history,metrics);applyFeatureControls();
});
})();