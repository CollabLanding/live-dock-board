(()=>{
 const style=document.createElement("style");style.textContent='.chat-typing-indicator{display:flex;align-items:center;gap:7px;min-height:20px;font-size:11px;color:var(--muted);visibility:hidden}.chat-typing-dots{display:inline-flex;gap:3px;align-items:center}.chat-typing-dots i{display:block;width:4px;height:4px;border-radius:50%;background:currentColor;animation:chat-typing-bounce 1.1s infinite ease-in-out}.chat-typing-dots i:nth-child(2){animation-delay:.15s}.chat-typing-dots i:nth-child(3){animation-delay:.3s}@keyframes chat-typing-bounce{0%,65%,100%{transform:translateY(0);opacity:.35}30%{transform:translateY(-3px);opacity:1}}@media(prefers-reduced-motion:reduce){.chat-typing-dots i{animation:none;opacity:1}}';document.head.appendChild(style);
 window.ChatTyping={create({client,input,form,anchor,getUser,canChat,name,channelName}){
  const indicator=document.createElement("div");indicator.className="chat-typing-indicator";indicator.dataset.noTranslate="true";indicator.setAttribute("role","status");indicator.setAttribute("aria-live","polite");anchor.before(indicator);
  let channel=null,local=null,ready=false,typing=false,idle=null,lastPublish=0,version=0,signature="";
  const esc=x=>String(x??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  function render(){
   const people=new Map(),now=Date.now();
   if(channel&&ready&&local)for(const metas of Object.values(channel.presenceState()))for(const meta of metas){if(meta.user_id!==local.id&&meta.typing===true&&now-Number(meta.updated_at)<6000&&now>=Number(meta.updated_at)-1000)people.set(meta.user_id,String(meta.name||"User").split("@")[0])}
   const names=[...people.values()].sort(),spanish=window.SiteLanguage?.current==="es";
   const next=JSON.stringify([names,spanish]);if(next===signature)return;signature=next;
   indicator.style.visibility=names.length?"visible":"hidden";indicator.setAttribute("aria-hidden",String(!names.length));
   if(!names.length){indicator.innerHTML="";return}
   const who=names.slice(0,3).join(", ")+(names.length>3?(spanish?" y ":" and ")+(names.length-3)+(spanish?" más":" others"):"");
   indicator.innerHTML='<span>'+esc(who)+(spanish?(names.length===1?" está escribiendo":" están escribiendo"):(names.length===1?" is typing":" are typing"))+'</span><span class="chat-typing-dots" aria-hidden="true"><i></i><i></i><i></i></span>';
  }
  function publish(force=false){
   if(!channel||!ready||!local)return;
   if(!force&&Date.now()-lastPublish<1000)return;
   lastPublish=Date.now();
   channel.track({user_id:local.id,name:String(name()||local.email?.split("@")[0]||"User").split("@")[0],typing,updated_at:Date.now()}).catch(()=>{});
  }
  function clear(){
   clearTimeout(idle);const was=typing;typing=false;if(was)publish(true);
  }
  function activity(){
   if(!local||!getUser()||!canChat()||!input.value.trim()){clear();return}
   const was=typing;typing=true;publish(!was);clearTimeout(idle);idle=setTimeout(clear,2500);
  }
  async function stop(){
   version++;clearTimeout(idle);typing=false;ready=false;local=null;
   const old=channel;channel=null;signature="";render();
   if(old){try{await old.untrack()}catch{}try{await client.removeChannel(old)}catch{}}
  }
  async function start(user){
   const stopped=stop(),current=version;await stopped;if(current!==version||!user||!canChat())return;
   local=user;
   channel=client.channel(channelName,{config:{presence:{key:user.id+"-"+crypto.randomUUID()}}}).on("presence",{event:"sync"},render).subscribe(status=>{
    if(current!==version)return;
    ready=status==="SUBSCRIBED";
    if(ready)publish(true);else{signature="";indicator.style.visibility="hidden";indicator.innerHTML=""}
   });
  }
  input.addEventListener("input",activity);input.addEventListener("blur",clear);form.addEventListener("submit",clear);
  window.addEventListener("pagehide",()=>{clear();channel?.untrack().catch(()=>{})});
  document.addEventListener("visibilitychange",()=>{if(document.hidden)clear()});
  document.addEventListener("site-language-changed",render);
  const sweep=setInterval(()=>{if(local&&!canChat())stop();else render()},1000);
  return {start,stop,activity,clear,destroy(){clearInterval(sweep);return stop()}};
 }};
})();
