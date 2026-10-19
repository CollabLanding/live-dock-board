(()=>{
"use strict";
const synth=window.speechSynthesis,supported=!!(synth&&window.SpeechSynthesisUtterance);
const ENABLED="yard-voice-enabled-v1",LANG="yard-voice-language-v1";
let enabled=false,armed=false,language=window.SiteLanguage?.current==="es"?"es":"en",client=null,channel=null,account=null,generation=0,pending=[],speaking=false,current=null;
const seen=new Set(),timers=new Set();
try{enabled=localStorage.getItem(ENABLED)==="true";language=localStorage.getItem(LANG)||window.SiteLanguage?.current||localStorage.getItem("operations-ui-language")||language}catch{}
language=language==="es"?"es":"en";
function dockList(numbers,es){
 const nums=[...new Set(numbers.map(Number).filter(Number.isInteger))].sort((a,b)=>a-b),parts=[];
 for(let i=0;i<nums.length;i++){let last=i;while(nums[last+1]===nums[last]+1)last++;parts.push(last-i>=2?nums[i]+(es?" a ":" through ")+nums[last]:nums.slice(i,last+1).join(", "));i=last}
 return parts.join(", ");
}
function describeRequest(r,lang){
 const es=lang==="es",source=es?"edificio "+r.building+", puerta "+r.dock_number:"Building "+r.building+", Dock "+r.dock_number;
 if(r.kind==="Adjust")return es?"Ajustar remolque en "+source+".":"Adjust trailer at "+source+".";
 if(r.kind==="Seal Check")return es?"Revisión de sello solicitada en "+source+".":"Seal check requested at "+source+".";
 if(r.kind!=="Move")return "";
 let destination=es?"edificio "+r.destinationBuilding:"Building "+r.destinationBuilding;
 if(r.destinationDock!=null)destination+=(es?", puerta ":", Dock ")+r.destinationDock;
 else if(r.groupDocks?.length)destination+=(es?", grupo de puertas ":", dock group ")+dockList(r.groupDocks,es);
 return es?"Mover desde "+source+" hacia "+destination+".":"Move from "+source+" to "+destination+".";
}
const controls=document.createElement("div");controls.className="voice-controls";controls.dataset.noTranslate="";
controls.innerHTML='<button type="button" class="secondary small" data-voice-toggle aria-pressed="false"></button><select data-voice-language aria-label="Voice language"><option value="en">English</option><option value="es">Español</option></select><span class="voice-status" role="status" aria-live="polite"></span>';
const host=document.querySelector(".topbar-actions");if(host)host.insertBefore(controls,document.getElementById("userEmail")||document.getElementById("userLabel"));
const toggle=controls.querySelector("[data-voice-toggle]"),picker=controls.querySelector("[data-voice-language]"),status=controls.querySelector(".voice-status");
function render(){toggle.disabled=!supported;picker.disabled=!supported;picker.value=language;toggle.setAttribute("aria-pressed",String(enabled&&armed));toggle.textContent=!supported?"Voice unavailable":armed&&enabled?"Voice On":"Enable Voice";toggle.title=armed&&enabled?"Turn off voice announcements":"Enable spoken dock requests on this device";status.textContent=enabled&&!armed&&supported?"Click to enable":""}
function clear(){generation++;for(const t of timers)clearTimeout(t);timers.clear();pending=[];speaking=false;current=null;if(supported)synth.cancel()}
function utter(text,done){
 const u=new SpeechSynthesisUtterance(text);u.lang=language==="es"?"es-MX":"en-US";
 const voices=synth.getVoices(),voice=voices.find(v=>v.lang===u.lang)||voices.find(v=>v.lang.toLowerCase().startsWith(language));if(voice)u.voice=voice;
 const volume=Number(document.getElementById("soundVolume")?.value||.5);u.volume=Number.isFinite(volume)?Math.max(0,Math.min(1,volume)):.5;u.rate=1;
 current=u;u.onend=()=>{if(current!==u)return;current=null;done()};
 u.onerror=e=>{if(current!==u)return;current=null;if(e.error==="not-allowed"){armed=false;pending=[];speaking=false;render();status.textContent="Click Enable Voice to resume";return}done()};
 synth.speak(u);
}
function pump(){
 if(speaking||!pending.length||!enabled||!armed||!account)return;
 speaking=true;const item=pending.shift(),token=generation;
 utter(describeRequest(item,language),()=>{if(token!==generation)return;speaking=false;pump()});
}
function assignment(h){
 const old=h.old_instruction_type||(h.old_move_to_building?"Move":null),kind=h.new_instruction_type||(h.new_move_to_building?"Move":null);
 return ["Move","Adjust","Seal Check"].includes(kind)&&(old!==kind||h.old_move_to_building!==h.new_move_to_building||h.old_move_to_dock_number!==h.new_move_to_dock_number||JSON.stringify(h.old_move_to_group||null)!==JSON.stringify(h.new_move_to_group||null));
}
async function receive(payload){
 const h=payload.new;if(!h?.id||seen.has(String(h.id)))return;
 seen.add(String(h.id));if(seen.size>2000)seen.delete(seen.values().next().value);
 if(!enabled||!armed||!account||!assignment(h)||h.activity_status==="Done")return;
 // Ignore an INSERT that merely replays or resurfaces an older request.
 if(payload.commit_timestamp&&h.changed_at&&Date.parse(payload.commit_timestamp)-Date.parse(h.changed_at)>30000)return;
 const token=generation;
 const timer=setTimeout(async()=>{
  timers.delete(timer);if(token!==generation||!armed||!enabled||!account)return;
  try{
   const r=await client.from("docks").select("id,instruction_type,move_to_building,move_to_dock_number,move_to_group").eq("id",h.dock_id).single();if(r.error||!r.data||token!==generation)return;
   const d=r.data,kind=h.new_instruction_type||(h.new_move_to_building?"Move":null);
   if(d.instruction_type!==kind||d.move_to_building!==h.new_move_to_building||d.move_to_dock_number!==h.new_move_to_dock_number||JSON.stringify(d.move_to_group||null)!==JSON.stringify(h.new_move_to_group||null))return;
   let groupDocks=null;
   if(h.new_move_to_group?.dock_ids?.length){
    const groups=await client.from("docks").select("dock_number").in("id",h.new_move_to_group.dock_ids);if(groups.error)return;groupDocks=groups.data.map(x=>x.dock_number);
   }
   if(token!==generation||!armed||!enabled||!account)return;
   pending.push({kind,building:h.building,dock_number:h.dock_number,destinationBuilding:h.new_move_to_building,destinationDock:h.new_move_to_dock_number,groupDocks});pump();
  }catch(e){console.warn("Voice announcement unavailable",e)}
 },300);timers.add(timer);
}
toggle.onclick=()=>{
 if(!supported)return;
 if(enabled&&armed){enabled=false;armed=false;clear()}
 else{clear();enabled=true;armed=true;utter(language==="es"?"Anuncios de voz activados.":"Voice announcements on.",()=>pump())}
 try{localStorage.setItem(ENABLED,String(enabled))}catch{}render();
};
picker.onchange=()=>{language=picker.value==="es"?"es":"en";try{localStorage.setItem(LANG,language)}catch{}};
window.DockVoice={
 describeRequest,
 connect(sb,userId){
  if(account===userId&&client===sb&&channel)return;
  clear();if(channel&&client)client.removeChannel(channel);
  client=sb;account=userId;seen.clear();
  channel=client.channel("dock-voice-requests").on("postgres_changes",{event:"INSERT",schema:"public",table:"dock_history"},receive).subscribe();
 },
 disconnect(){clear();if(channel&&client)client.removeChannel(channel);channel=null;account=null;seen.clear()},
 receive
};
window.addEventListener("pagehide",()=>clear());render();
})();
