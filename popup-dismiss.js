(()=>{
"use strict";
// Use the same cancellation path as Escape, including each screen's save guards.
let startedOutside=null;
function outsideDialog(event){
 const d=event.target;
 if(!d||d.tagName!=="DIALOG"||!d.open)return null;
 const r=d.getBoundingClientRect();
 return event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom?d:null;
}
document.addEventListener("pointerdown",event=>{
 startedOutside=event.button===0&&event.isPrimary!==false?outsideDialog(event):null;
},true);
document.addEventListener("pointercancel",()=>{startedOutside=null},true);
document.addEventListener("click",event=>{
 const d=outsideDialog(event),started=startedOutside;startedOutside=null;
 if(!d)return;
 // Keep a drag that began inside the screen from dismissing it.
 event.stopImmediatePropagation();
 if(d!==started||event.button!==0)return;
 const cancel=new Event("cancel",{cancelable:true,bubbles:false});
 if(d.dispatchEvent(cancel)&&d.open)d.close();
},true);
})();
