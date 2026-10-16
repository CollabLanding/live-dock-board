(()=>{
"use strict";
const targets=new Set(["transfers","transfer_slot_statuses","docks"]);
const cache=new Map(),pins=new Map(),stats={saves:[],sync:[],connections:new Map()};
let client=null,dialog=null,historyBefore=null,historyRows=[];
const key=(t,id)=>t+":"+id;
function remember(table,rows){for(const row of Array.isArray(rows)?rows:[rows])if(row?.id&&row.edit_revision!=null){const k=key(table,row.id),old=cache.get(k);if(!old||Number(row.edit_revision)>=Number(old.edit_revision))cache.set(k,{...old,...row});}}
function showConflict(table,current,patch){
 const d=document.createElement("dialog");d.className="edit-review";
 const h=document.createElement("h2");h.textContent="This record changed";
 const p=document.createElement("p");p.textContent="Your save was not applied. Your attempted changes are recorded in Edit history. Review the latest version before saving again.";
 const before=document.createElement("pre");before.textContent="Your requested changes\n"+JSON.stringify(patch,null,2)+"\n\nCurrent saved version\n"+JSON.stringify(current,null,2);
 const keep=document.createElement("button");keep.textContent="Keep my draft";keep.onclick=()=>d.close();
 const latest=document.createElement("button");latest.textContent="Load latest version";latest.onclick=()=>{
  Object.values(current||{}).forEach(row=>{pins.delete(key(table,row.id));remember(table,row)});
  document.dispatchEvent(new CustomEvent("edit-load-latest",{detail:{table,rows:Object.values(current||{})}}));d.close();
 };
 d.append(h,p,before,keep,latest);document.body.append(d);d.addEventListener("close",()=>d.remove(),{once:true});d.showModal();
}
function mutation(sb,table,patch,operation){
 let ids=[],single=false,selected=false,invalid=false,promise;
 const expected={};
 function capture(values){ids=values.map(String);for(const id of ids){const row=pins.get(key(table,id))||cache.get(key(table,id));if(row?.edit_revision!=null)expected[id]=row.edit_revision;}}
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
    remember(table,r.data.rows);
    for(const row of r.data.rows||[])if(pins.has(key(table,row.id)))pins.set(key(table,row.id),{...row});
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
 const sb=originalCreate(...args);if(!client)client=sb;
 const from=sb.from.bind(sb),channel=sb.channel.bind(sb),rpc=sb.rpc.bind(sb);
 const guardedActions=new Set(["set_docks_hidden","assign_dock_trailer","release_dock_trailer","complete_seal_check","respond_dock_activity","save_dock_details"]);
 sb.rpc=async(name,args,...rest)=>{
  if(!guardedActions.has(name))return rpc(name,args,...rest);
  const expected={};
  for(const [k,row] of cache)if(k.startsWith("docks:")){const baseline=pins.get(k)||row;if(baseline.edit_revision!=null)expected[row.id]=baseline.edit_revision;}
  const started=performance.now(),r=await rpc("guarded_dock_action",{p_action:name,p_args:args,p_expected:expected});
  stats.saves.push(performance.now()-started);if(stats.saves.length>100)stats.saves.shift();
  if(r.error)return r;
  if(!r.data?.ok){
   if(r.data?.conflict){Object.values(r.data.current||{}).forEach(row=>remember("docks",row));showConflict("docks",r.data.current,args);}
   return {data:null,error:{message:r.data?.message||"Dock action not applied.",code:r.data?.conflict?"EDIT_CONFLICT":"EDIT_REJECTED"}};
  }
  remember("docks",r.data.rows);
  for(const row of r.data.rows||[])if(pins.has(key("docks",row.id)))pins.set(key("docks",row.id),row);
  return {data:r.data.result,error:null};
 };
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
 if(!client)return;
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
 const d=document.createElement("dialog");d.className="edit-review";
 const h=document.createElement("h2");h.textContent="Live connection";
 const p=document.createElement("p"),mean=a=>a.length?Math.round(a.reduce((x,y)=>x+y,0)/a.length)+" ms":"No samples yet";
 p.style.whiteSpace="pre-wrap";p.textContent="Average save round trip: "+mean(stats.saves)+"\nAverage server-to-browser event delay (estimated): "+mean(stats.sync)+"\n\n"+[...stats.connections].map(([name,status])=>name+": "+status).join("\n")+"\n\nEvent delay depends on computer clock accuracy and excludes the sender's save time. These are samples from this tab.";
 const close=document.createElement("button");close.textContent="Close";close.onclick=()=>d.close();d.append(h,p,close);document.body.append(d);d.onclose=()=>d.remove();d.showModal();
}
document.addEventListener("DOMContentLoaded",()=>{
 const style=document.createElement("style");style.textContent='.edit-review{width:min(880px,94vw);max-height:85vh;overflow:auto;border:1px solid var(--border,var(--line,#64748b));border-radius:14px;padding:20px;background:var(--panel,#fff);color:var(--text,#17212b)}.edit-review::backdrop{background:#0009}.edit-review pre{white-space:pre-wrap;overflow-wrap:break-word;font:12px/1.5 monospace}.edit-review button{margin:5px;padding:7px 12px}.edit-review article{border-bottom:1px solid #8886;padding:12px 0}.edit-review article div{font-size:12px;opacity:.8}';document.head.append(style);
 const anchor=document.querySelector(".topbar-actions,.topbar .user-session,.user-session,.topbar");
 if(!anchor)return;
 const history=document.createElement("button");history.type="button";history.className="secondary small";history.textContent="Edit history";history.onclick=openHistory;
 const metrics=history.cloneNode();metrics.textContent="Live connection";metrics.onclick=openMetrics;anchor.append(history,metrics);
});
})();