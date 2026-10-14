window.createDockAccess=(sb,getUser)=>{
 let role=null,permissions={},signature=null,generation=0,catalog=[],draft=null,revision=null,dirty=false,saving=false;
 const can=key=>role==="Owner"||permissions[key]===true,isAdmin=()=>["Owner","Admin"].includes(role),canEdit=r=>role==="Owner"||role==="Admin"&&r!=="Admin";
 const esc=value=>String(value??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
 const dialog=document.createElement("dialog");dialog.className="access-dialog";dialog.setAttribute("aria-labelledby","dockAccessTitle");
 dialog.innerHTML='<div class="access-heading"><h2 id="dockAccessTitle">User Access</h2><button id="dockAccessClose" type="button" aria-label="Close user access">×</button></div><div class="access-tools"><button id="dockAccessRefresh" type="button">Refresh</button><button id="dockPermissionsOpen" type="button">Permissions</button></div><p id="dockAccessMessage" role="status"></p><div id="dockUserTableWrap" class="access-scroll"><table><thead><tr><th>Email</th><th>Role</th><th></th></tr></thead><tbody id="dockUserRows"></tbody></table></div><section id="dockPermissionsPanel" hidden><p>Admins can edit User and Driver permissions. Only the Owner can edit Admin permissions. Required parent features are selected automatically.</p><div class="access-scroll"><table><thead><tr><th>Feature</th><th>Admin</th><th>User</th><th>Driver</th></tr></thead><tbody id="dockPermissionRows"></tbody></table></div><p id="dockPermissionsMessage" role="status"></p><button id="dockPermissionsSave" type="button">Save Permissions</button></section>';
 document.body.appendChild(dialog);const $=id=>dialog.querySelector("#"+id);
 function apply(){
  const map={"#summaryCards,.dock-board-panel,.yard-label,.legend,.active-trailers-panel":"view_board",".dock-history-panel":"view_activity",".chat-panel":"chat","#clearChatHistory":"clear_chat",".active-users-panel":"active_users",".theme-switch":"theme",".sound-controls":"sounds",".topbar-page-link":"transfers_link","#statusToggle,#statusPanel,#batchStatusOptionGrid,#batchCustomWrap":"update_status","#moveToggle,#movePanel,#batchInstructionTypeGrid,#batchClearRequest,#batchMoveBuildingWrap":"request_moves","#hideDockButton,#hideBatchDocks":"hide_docks",".activity-response-btn,.seal-done-btn":"respond_moves"};
  for(const [selector,key]of Object.entries(map))document.querySelectorAll(selector).forEach(node=>node.dataset.dockDenied=String(!can(key)));
  document.querySelectorAll(".dock-hidden-bar").forEach(node=>node.disabled=!can("hide_docks"));
  document.querySelectorAll("#applyUpdate").forEach(node=>node.dataset.dockDenied=String(!can("update_status")&&!can("request_moves")));
  const link=document.getElementById("dockAccessLink");const allowed=isAdmin()&&(can("manage_users")||can("view_permissions"));if(link)link.hidden=!allowed;const top=document.getElementById("dockAccessTop");if(top)top.hidden=!allowed;const title=document.getElementById("dockActiveTitle");if(title)title.hidden=allowed;
  const roleLabel=document.getElementById("dockRoleLabel");if(roleLabel&&roleLabel.textContent!==(role||""))roleLabel.textContent=role||"";
  $("dockPermissionsOpen").hidden=!can("view_permissions");$("dockAccessRefresh").hidden=!can("manage_users");$("dockUserTableWrap").hidden=!can("manage_users");
 }
 async function refresh(){
  const version=++generation;if(!getUser()){role=null;permissions={};apply();return}
  const r=await sb.rpc("get_dock_access");if(version!==generation)return;if(r.error)throw r.error;
  role=r.data?.role||"Driver";permissions=r.data?.permissions||{};
  const next=JSON.stringify([role,permissions]);if(signature&&signature!==next){location.reload();return}signature=next;apply();
 }
 async function users(){
  if(!can("manage_users"))return;$("dockAccessMessage").textContent="Loading users…";
  const r=await sb.rpc("list_dock_users");if(r.error){$("dockAccessMessage").textContent=r.error.message;return}
  $("dockUserRows").innerHTML=(r.data||[]).map(user=>{const locked=user.role==="Owner"||user.id===getUser()?.id;return '<tr data-user="'+esc(user.id)+'"><td>'+esc(String(user.email||'').split('@')[0])+'</td><td>'+(locked?esc(user.role)+(user.role==="Owner"?" · Protected":" · Your account"):'<select aria-label="Role for '+esc(String(user.email||'').split('@')[0])+'">'+["Admin","User","Driver"].map(r=>'<option'+(r===user.role?' selected':'')+'>'+r+'</option>').join("")+'</select>')+'</td><td>'+(locked?"":'<button type="button">Save</button>')+'</td></tr>'}).join("");
  $("dockUserRows").querySelectorAll("button").forEach(button=>button.onclick=async()=>{const row=button.closest("tr");button.disabled=true;const r=await sb.rpc("set_dock_user_role",{p_user_id:row.dataset.user,p_role:row.querySelector("select").value});button.disabled=false;if(r.error){$("dockAccessMessage").textContent=r.error.message;return}await users();$("dockAccessMessage").textContent="Role saved."});
  $("dockAccessMessage").textContent=(r.data||[]).length+" registered users";
 }
 function renderGrid(){
  $("dockPermissionRows").innerHTML=catalog.map(f=>'<tr><th>'+esc(f.label)+'</th>'+["Admin","User","Driver"].map(r=>'<td><input type="checkbox" data-role="'+r+'" data-feature="'+f.key+'" aria-label="'+esc(r+": "+f.label)+'"'+(draft[r][f.key]?' checked':'')+(!canEdit(r)||f.fixed||f.adminOnly&&r!=="Admin"?' disabled':'')+'></td>').join("")+'</tr>').join("");
  $("dockPermissionsSave").disabled=!dirty||saving;
 }
 async function grid(){
  $("dockPermissionsPanel").hidden=false;$("dockPermissionsMessage").textContent="Loading permissions…";
  const r=await sb.rpc("get_dock_role_permissions");if(r.error){$("dockPermissionsMessage").textContent=r.error.message;return}
  catalog=r.data.catalog;draft=r.data.roles;revision=r.data.revision;dirty=false;renderGrid();$("dockPermissionsMessage").textContent="";
 }
 function set(r,key,value,seen=new Set()){
  if(seen.has(key))return;seen.add(key);draft[r][key]=value;
  if(value)for(const parent of catalog.find(f=>f.key===key)?.dependencies||[])set(r,parent,true,seen);
  else for(const child of catalog.filter(f=>f.dependencies.includes(key)))set(r,child.key,false,seen);
 }
 $("dockPermissionRows").addEventListener("change",event=>{const node=event.target;if(saving||!node.matches("input[data-role]")||!canEdit(node.dataset.role))return;set(node.dataset.role,node.dataset.feature,node.checked);dirty=true;renderGrid();$("dockPermissionsMessage").textContent="Unsaved changes."});
 $("dockPermissionsSave").onclick=async()=>{if(!dirty||saving)return;saving=true;renderGrid();const r=await sb.rpc("save_dock_role_permissions",{p_roles:draft,p_revision:revision});saving=false;if(r.error){renderGrid();$("dockPermissionsMessage").textContent=r.error.message;return}await grid();$("dockPermissionsMessage").textContent="Permissions saved.";await refresh()};
 $("dockPermissionsOpen").onclick=grid;$("dockAccessRefresh").onclick=users;$("dockAccessClose").onclick=()=>dialog.close();
 ["dockAccessLink","dockAccessTop"].forEach(id=>document.getElementById(id)?.addEventListener("click",async event=>{event.preventDefault();if(!isAdmin())return;dialog.showModal();$("dockPermissionsPanel").hidden=true;if(can("manage_users"))await users();else await grid()}));
 new MutationObserver(apply).observe(document.getElementById("boardScreen"),{childList:true,subtree:true});
 setInterval(()=>{if(getUser()&&!document.hidden)refresh().catch(()=>{})},30000);window.addEventListener("focus",()=>{if(getUser())refresh().catch(()=>{})});
 return {can,isAdmin,apply,refresh,get role(){return role}};
};