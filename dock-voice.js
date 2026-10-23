(()=>{
"use strict";
const synth=window.speechSynthesis,supported=!!(synth&&window.SpeechSynthesisUtterance);
const ENABLED="yard-voice-enabled-v1",LANG="yard-voice-language-v1",VOICE="yard-voice-selection-v1";
let chosenVoices={};try{chosenVoices=JSON.parse(localStorage.getItem(VOICE)||"{}")||{}}catch{}
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
 const es=lang==="es",source=es?"edificio "+r.building+", puerta "+dockNumber(r.dock_number,r.building):"Building "+r.building+", Dock "+dockNumber(r.dock_number,r.building);
 if(r.kind==="Need An Empty")return es?"Se necesita un remolque vacío en "+source+".":"Empty trailer needed at "+source+".";
 if(r.kind==="Adjust")return es?"Ajustar remolque en "+source+".":"Adjust trailer at "+source+".";
 if(r.kind==="Seal Check")return es?"Revisión de sello solicitada en "+source+".":"Seal check requested at "+source+".";
 if(r.kind!=="Move")return "";
 let destination=es?"edificio "+r.destinationBuilding:"Building "+r.destinationBuilding;
 if(r.destinationDock!=null)destination+=(es?", puerta ":", Dock ")+dockNumber(r.destinationDock,r.destinationBuilding);
 else if(r.groupName)destination+=(es?", grupo ":", group ")+r.groupName;
 return es?"Mover desde "+source+" hacia "+destination+".":"Move from "+source+" to "+destination+".";
}
const controls=document.createElement("div");controls.className="voice-controls";controls.dataset.noTranslate="";
controls.innerHTML='<button type="button" class="secondary small" data-voice-open aria-haspopup="dialog" aria-controls="dockVoiceOptions">Voice</button>';
const host=document.querySelector(".topbar-actions");if(host)host.insertBefore(controls,document.getElementById("userEmail")||document.getElementById("userLabel"));
const dialog=document.createElement("dialog");dialog.id="dockVoiceOptions";dialog.className="dock-voice-dialog";dialog.dataset.noTranslate="";
dialog.setAttribute("aria-labelledby","dockVoiceTitle");
dialog.innerHTML='<div class="dock-voice-heading"><h2 id="dockVoiceTitle">Voice</h2><button type="button" data-voice-close aria-label="Close voice options">×</button></div><button type="button" class="secondary" data-voice-toggle aria-pressed="false"></button><label>Language<select data-voice-language><option value="en">English</option><option value="es">Español</option></select></label><label>Device Voice<select data-device-voice aria-label="Device voice"></select></label><button type="button" class="secondary" data-voice-preview>Preview Voice</button><p class="voice-status" role="status" aria-live="polite"></p>';
document.body.append(dialog);
const toggle=dialog.querySelector("[data-voice-toggle]"),picker=dialog.querySelector("[data-voice-language]"),voicePicker=dialog.querySelector("[data-device-voice]"),preview=dialog.querySelector("[data-voice-preview]"),status=dialog.querySelector(".voice-status");
function availableVoices(){return supported?synth.getVoices().filter(v=>v.lang.toLowerCase().startsWith(language)):[]}
function loadVoices(){
 voicePicker.replaceChildren(new Option("Device default",""));
 for(const v of availableVoices())voicePicker.append(new Option(v.name+" ("+v.lang+")",v.voiceURI));
 voicePicker.value=availableVoices().some(v=>v.voiceURI===chosenVoices[language])?chosenVoices[language]:"";
}
function render(){
 toggle.disabled=!supported;picker.disabled=!supported;voicePicker.disabled=!supported;preview.disabled=!supported||speaking;picker.value=language;toggle.setAttribute("aria-pressed",String(enabled&&armed));
 toggle.textContent=!supported?"Voice unavailable":armed&&enabled?"Turn Voice Off":"Enable Voice";
 status.textContent=!supported?"Voice announcements are unavailable in this browser.":enabled&&!armed?"Click Enable Voice to activate announcements.":"";
}
controls.querySelector("[data-voice-open]").onclick=()=>{loadVoices();render();dialog.showModal()};
dialog.querySelector("[data-voice-close]").onclick=()=>dialog.close();
if(supported)synth.addEventListener?.("voiceschanged",loadVoices);
voicePicker.onchange=()=>{chosenVoices[language]=voicePicker.value;try{localStorage.setItem(VOICE,JSON.stringify(chosenVoices))}catch{}};
preview.onclick=()=>{
 if(!supported||speaking)return;
 speaking=true;render();utter(describeRequest({kind:"Move",building:100,dock_number:12,destinationBuilding:200,destinationDock:35},language),()=>{speaking=false;render();pump()});
};
function clear(){generation++;for(const t of timers)clearTimeout(t);timers.clear();pending=[];speaking=false;current=null;if(supported)synth.cancel()}
function utter(text,done){
 const u=new SpeechSynthesisUtterance(text);u.lang=language==="es"?"es-MX":"en-US";
 const voices=availableVoices(),voice=voices.find(v=>v.voiceURI===chosenVoices[language])||voices.find(v=>v.lang===u.lang)||voices[0];if(voice){u.voice=voice;u.lang=voice.lang}
 const volume=Number(document.getElementById("soundVolume")?.value||.5);u.volume=Number.isFinite(volume)?Math.max(0,Math.min(1,volume)):.5;u.rate=1;
 current=u;u.onend=()=>{if(current!==u)return;current=null;done()};
 u.onerror=e=>{if(current!==u)return;current=null;if(e.error==="not-allowed"){armed=false;pending=[];speaking=false;render();status.textContent="Open Voice and click Enable Voice to resume";return}done()};
 synth.speak(u);
}
function pump(){
 if(speaking||!pending.length||!enabled||!armed||!account)return;
 speaking=true;render();const item=pending.shift(),token=generation;
 utter(describeRequest(item,language),()=>{if(token!==generation)return;speaking=false;render();pump()});
}
function assignment(h){
 const old=h.old_instruction_type||(h.old_move_to_building?"Move":null),kind=h.new_instruction_type||(h.new_move_to_building?"Move":null);
 return ["Move","Adjust","Seal Check"].includes(kind)&&(old!==kind||h.old_move_to_building!==h.new_move_to_building||h.old_move_to_dock_number!==h.new_move_to_dock_number||JSON.stringify(h.old_move_to_group||null)!==JSON.stringify(h.new_move_to_group||null));
}
async function receive(payload){
 const h=payload.new;if(!h?.id||seen.has(String(h.id)))return;
 seen.add(String(h.id));if(seen.size>2000)seen.delete(seen.values().next().value);
 const needsEmpty=h.new_status==="Need An Empty"&&h.old_status!=="Need An Empty";
 if(!enabled||!armed||!account||(!assignment(h)&&!needsEmpty)||h.activity_status==="Done")return;
 // Ignore an INSERT that merely replays or resurfaces an older request.
 if(payload.commit_timestamp&&h.changed_at&&Date.parse(payload.commit_timestamp)-Date.parse(h.changed_at)>30000)return;
 const token=generation;
 const timer=setTimeout(async()=>{
  timers.delete(timer);if(token!==generation||!armed||!enabled||!account)return;
  try{
   const r=await client.from("docks").select("id,status,instruction_type,move_to_building,move_to_dock_number,move_to_group").eq("id",h.dock_id).single();if(r.error||!r.data||token!==generation)return;
   const d=r.data,kind=h.new_instruction_type||(h.new_move_to_building?"Move":null);
   const activeMove=assignment(h)&&d.instruction_type===kind&&d.move_to_building===h.new_move_to_building&&d.move_to_dock_number===h.new_move_to_dock_number&&JSON.stringify(d.move_to_group||null)===JSON.stringify(h.new_move_to_group||null);
   const activeEmpty=needsEmpty&&d.status==="Need An Empty";
   if(!activeMove&&!activeEmpty)return;
   const groupName=h.new_move_to_group?.title||null;
   if(token!==generation||!armed||!enabled||!account)return;
   if(activeEmpty)pending.push({kind:"Need An Empty",building:h.building,dock_number:h.dock_number});
   if(activeMove)pending.push({kind,building:h.building,dock_number:h.dock_number,destinationBuilding:h.new_move_to_building,destinationDock:h.new_move_to_dock_number,groupName});pump();
  }catch(e){console.warn("Voice announcement unavailable",e)}
 },300);timers.add(timer);
}
toggle.onclick=()=>{
 if(!supported)return;
 if(enabled&&armed){enabled=false;armed=false;clear()}
 else{clear();enabled=true;armed=true;speaking=true;utter(language==="es"?"Anuncios de voz activados.":"Voice announcements on.",()=>{speaking=false;render();pump()})}
 try{localStorage.setItem(ENABLED,String(enabled))}catch{}render();
};
picker.onchange=()=>{language=picker.value==="es"?"es":"en";try{localStorage.setItem(LANG,language)}catch{}loadVoices()};
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
window.addEventListener("pagehide",()=>clear());loadVoices();render();
})();
