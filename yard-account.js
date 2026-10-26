(()=>{
 const button=document.getElementById("userEmail")||document.getElementById("userLabel");if(!button)return;
 const dialog=document.createElement("dialog");dialog.className="yard-account-dialog";dialog.setAttribute("aria-labelledby","yardAccountTitle");dialog.innerHTML='<div class="yard-account-heading"><h2 id="yardAccountTitle">Account Options</h2><button type="button" id="closeYardAccount" aria-label="Close">×</button></div><dl><dt>Account Type</dt><dd id="accountRole"></dd><dt>Username</dt><dd id="accountUsername" data-no-translate></dd><dt>Email</dt><dd id="accountEmail" data-no-translate></dd></dl><h3>Language</h3><div id="yardAccountLanguage"></div><p><a href="#changePassword" id="yardChangePassword" aria-expanded="false" aria-controls="yardPasswordForm">Change Password</a></p><form id="yardPasswordForm" hidden data-no-translate><h3 id="yardPasswordTitle"></h3><label><span id="yardNewPasswordLabel"></span><input id="yardNewPassword" type="password" autocomplete="new-password" minlength="8" required></label><label><span id="yardConfirmPasswordLabel"></span><input id="yardConfirmPassword" type="password" autocomplete="new-password" minlength="8" required></label><p id="yardPasswordMessage" role="status" aria-live="polite"></p><button id="yardSavePassword" class="primary" type="submit"></button></form>';
 document.body.appendChild(dialog);
 const roleLabel=document.getElementById("dockRoleLabel");
 if(roleLabel)dialog.querySelector("#accountRole").appendChild(roleLabel);
 const signOut=document.getElementById("signOutBtn")||document.getElementById("signOut");
 if(signOut){signOut.type="button";const actions=document.createElement("div");actions.style.marginTop="20px";actions.appendChild(signOut);dialog.appendChild(actions);}
 const audio=document.createElement("section");audio.className="yard-account-audio";audio.innerHTML="<h3>Sound & Voice</h3>";
 for(const selector of [".sound-controls",".voice-controls"]){const control=document.querySelector(".topbar-actions "+selector);if(control)audio.appendChild(control)}
 dialog.querySelector("#yardAccountLanguage").before(audio);
 window.SiteLanguage.mount(dialog.querySelector("#yardAccountLanguage"));
 button.addEventListener("click",()=>{if(!roleLabel)dialog.querySelector("#accountRole").textContent=button.dataset.accountRole||"";const email=button.dataset.accountEmail||button.textContent;dialog.querySelector("#accountUsername").textContent=email.split("@")[0];dialog.querySelector("#accountEmail").textContent=button.dataset.accountEmail||"";resetPassword();dialog.showModal();window.SiteLanguage.apply()});
 const form=dialog.querySelector("#yardPasswordForm"),newPassword=dialog.querySelector("#yardNewPassword"),confirmPassword=dialog.querySelector("#yardConfirmPassword"),passwordMessage=dialog.querySelector("#yardPasswordMessage"),savePassword=dialog.querySelector("#yardSavePassword");
 let working=false;
 const words=()=>window.SiteLanguage.current==="es"?{title:"Cambiar contraseña",newLabel:"Nueva contraseña",confirmLabel:"Confirmar contraseña",save:"Cambiar contraseña",saving:"Guardando…",mismatch:"Las contraseñas no coinciden.",signedOut:"Inicia sesión para cambiar tu contraseña.",success:"Contraseña actualizada.",error:"No se pudo cambiar la contraseña."}:{title:"Change Password",newLabel:"New Password",confirmLabel:"Confirm Password",save:"Change Password",saving:"Saving…",mismatch:"Passwords do not match.",signedOut:"Sign in to change your password.",success:"Password updated.",error:"Could not change your password."};
 function labels(){const w=words();dialog.querySelector("#yardChangePassword").textContent=w.title;dialog.querySelector("#yardPasswordTitle").textContent=w.title;dialog.querySelector("#yardNewPasswordLabel").textContent=w.newLabel;dialog.querySelector("#yardConfirmPasswordLabel").textContent=w.confirmLabel;savePassword.textContent=working?w.saving:w.save}
 function resetPassword(){form.reset();form.hidden=true;newPassword.disabled=true;confirmPassword.disabled=true;dialog.querySelector("#yardChangePassword").setAttribute("aria-expanded","false");passwordMessage.textContent="";labels()}
 dialog.querySelector("#yardChangePassword").onclick=event=>{event.preventDefault();form.hidden=false;newPassword.disabled=false;confirmPassword.disabled=false;event.currentTarget.setAttribute("aria-expanded","true");labels();newPassword.focus()};
 document.addEventListener("site-language-changed",labels);
 form.addEventListener("submit",async event=>{
  event.preventDefault();if(working)return;const w=words();
  if(newPassword.value!==confirmPassword.value){passwordMessage.textContent=w.mismatch;confirmPassword.focus();return}
  const auth=window.YardAccountAuth;if(!auth){passwordMessage.textContent=w.signedOut;return}
  working=true;savePassword.disabled=true;labels();passwordMessage.textContent=w.saving;
  const password=newPassword.value;newPassword.disabled=true;confirmPassword.disabled=true;
  try{
   const current=await auth.getUser();if(current.error)throw current.error;
   if(!current.data.user)throw new Error(w.signedOut);
   const result=await auth.updateUser({password});if(result.error)throw result.error;
   form.reset();passwordMessage.textContent=w.success;
  }catch(error){passwordMessage.textContent=error.message||w.error}
  finally{working=false;newPassword.disabled=false;confirmPassword.disabled=false;savePassword.disabled=false;labels()}
 });
 dialog.addEventListener("close",resetPassword);
 dialog.addEventListener("cancel",event=>{if(working)event.preventDefault()});
 dialog.querySelector("#closeYardAccount").onclick=()=>{if(!working)dialog.close()};
 for(const id of ["signOutBtn","signOut"])document.getElementById(id)?.addEventListener("click",()=>dialog.close());
 resetPassword();
 const style=document.createElement("style");style.textContent='.yard-account-audio{display:grid;gap:12px}.yard-account-audio h3{margin:12px 0 0}.yard-account-audio .sound-controls{display:flex;align-items:center;gap:12px;flex-wrap:wrap}.yard-account-audio .sound-volume{display:flex;align-items:center;gap:6px;font-size:12px}.yard-account-audio select{width:auto;min-height:36px;padding:6px 8px;border:1px solid var(--border);border-radius:9px;background:var(--panel);color:var(--text)}.yard-account-audio button{min-height:36px;padding:7px 10px;border:1px solid var(--border);border-radius:10px;background:var(--panel);color:var(--text);font-size:13px;font-weight:800;cursor:pointer}.yard-account-dialog [hidden]{display:none!important}.user-email,.yard-account-toggle{border:0!important;background:transparent!important;color:var(--muted);padding:0!important;min-height:0!important;font-size:13px;font-weight:700;cursor:pointer}.user-email:hover,.yard-account-toggle:hover{color:var(--accent);text-decoration:underline}.yard-account-dialog{width:min(410px,calc(100vw - 24px));border:1px solid var(--border);border-radius:14px;padding:22px;background:var(--panel);color:var(--text)}.yard-account-dialog::backdrop{background:rgba(15,23,42,.65)}.yard-account-heading{display:flex;align-items:center;justify-content:space-between;gap:12px}.yard-account-heading h2{font-size:20px;margin:0}.yard-account-heading button{border:0;background:transparent;color:var(--text);font-size:24px}.yard-account-dialog dt{font-size:12px;color:var(--muted);margin-top:16px}.yard-account-dialog dd{margin:4px 0 0;font-size:14px;font-weight:700}.yard-account-dialog h3{font-size:13px;margin-top:24px}.yard-account-dialog form label{display:grid;gap:6px;margin-top:12px;font-size:13px}.yard-account-dialog form input{box-sizing:border-box;width:100%;padding:10px;border:1px solid var(--border);border-radius:8px;background:var(--panel);color:var(--text)}.yard-account-dialog form button{padding:10px 14px;border-radius:8px;cursor:pointer}.yard-account-dialog form p{font-size:13px;min-height:18px}.yard-account-dialog{max-height:90vh;overflow:auto}';document.head.appendChild(style);
})();
