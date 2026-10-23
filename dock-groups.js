window.createDockGroupManager=function(sb,getDocks,isAdmin){
 const dialog=document.createElement("dialog");dialog.className="dock-groups-dialog";
 dialog.innerHTML='<div class="dialog-heading"><h2>Grouping</h2><button type="button" data-close aria-label="Close">×</button></div><div class="group-tools"><select data-existing aria-label="Saved grouping"><option value="">New grouping</option></select><button type="button" data-new>New</button></div><form><div class="row"><label>Title<input data-title maxlength="80" required></label><label>Building<select data-building><option value="100">Building 100</option><option value="200">Building 200</option></select></label></div><div data-docks></div><p data-message role="status"></p><div class="form-actions"><button type="button" class="danger" data-delete hidden>Delete Group</button><button type="button" data-close>Cancel</button><button class="primary" data-save>Save Group</button></div></form>';
 document.body.append(dialog);const $=s=>dialog.querySelector(s);
 let groups=[],editing=null,selected=new Set(),saving=false;
 const message=text=>$("[data-message]").textContent=text;
 function draw(){
  const building=Number($("[data-building]").value),host=$("[data-docks]");host.replaceChildren();
  for(const n of [100,200]){
   const section=document.createElement("section"),h=document.createElement("h3"),grid=document.createElement("div");h.textContent="Building "+n;grid.className="group-dock-grid";
   for(const dock of getDocks().filter(d=>Number(d.building)===n).sort((a,b)=>dockPosition(a.building,a.dock_number)-dockPosition(b.building,b.dock_number))){
    const b=document.createElement("button");b.type="button";b.textContent=dockNumber(dock.dock_number,dock.building);b.disabled=saving||building!==n;b.className=selected.has(dock.id)?"selected":"";b.setAttribute("aria-pressed",String(selected.has(dock.id)));b.title="Building "+n+" · Dock "+dockNumber(dock.dock_number,dock.building)+" · "+dock.side;
    b.onclick=()=>{if(selected.has(dock.id))selected.delete(dock.id);else selected.add(dock.id);draw();message(selected.size+" docks selected")};grid.append(b);
   }
   section.append(h,grid);host.append(section);
  }
 }
 function choose(id=""){editing=groups.find(g=>g.id===id)||null;selected=new Set(editing?.dock_ids||[]);$("[data-existing]").value=editing?.id||"";$("[data-title]").value=editing?.title||"";$("[data-building]").value=String(editing?.building||100);$("[data-delete]").hidden=!editing;message("");draw()}
 async function load(){const r=await sb.from("dock_groups").select("*").order("building").order("title");if(r.error)throw r.error;groups=r.data||[];const picker=$("[data-existing]");picker.replaceChildren(new Option("New grouping",""));for(const g of groups)picker.append(new Option("B"+g.building+" · "+g.title,g.id))}
 function close(){if(!saving)dialog.close()}
 dialog.querySelectorAll("[data-close]").forEach(b=>b.onclick=close);dialog.addEventListener("cancel",e=>{if(saving)e.preventDefault()});
 $("[data-existing]").onchange=e=>choose(e.target.value);$("[data-new]").onclick=()=>choose();$("[data-building]").onchange=()=>{selected.clear();draw();message("")};
 async function work(fn){saving=true;dialog.querySelectorAll("button,input,select").forEach(n=>n.disabled=true);try{await fn()}catch(e){message(e.message)}finally{saving=false;dialog.querySelectorAll("button,input,select").forEach(n=>n.disabled=false);draw()}}
 $("form").onsubmit=e=>{e.preventDefault();if(saving||!isAdmin())return;if(!selected.size){message("Select at least one dock.");return}work(async()=>{
  const r=await sb.rpc("save_dock_group",{p_id:editing?.id||null,p_title:$("[data-title]").value.trim(),p_building:Number($("[data-building]").value),p_dock_ids:[...selected],p_revision:editing?.revision||null});if(r.error)throw r.error;
  await load();choose(r.data.id);message("Grouping saved.");
 })};
 $("[data-delete]").onclick=()=>{if(!editing||saving||!confirm("Delete this grouping? Existing Move requests will keep their destination."))return;work(async()=>{const r=await sb.from("dock_groups").delete().eq("id",editing.id).eq("revision",editing.revision).select("id");if(r.error)throw r.error;if(!r.data?.length)throw new Error("This grouping changed. Reopen it before deleting.");await load();choose();message("Grouping deleted.")})};
 return {async open(){if(!isAdmin())return;dialog.showModal();message("Loading…");try{await load();choose()}catch(e){message(e.message)}},close,draw};
};
