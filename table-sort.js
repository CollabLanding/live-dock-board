(() => {
 const css=document.createElement("style");css.textContent='.table-sort-button{display:inline-flex;align-items:center;gap:6px;margin:0;padding:0!important;min-height:0!important;border:0!important;border-radius:0;background:transparent!important;color:inherit;font:inherit;font-weight:inherit;cursor:pointer;white-space:nowrap}.table-sort-button:focus-visible{outline:2px solid var(--accent);outline-offset:4px}.table-sort-arrow{font-size:10px;color:var(--accent)}';document.head.appendChild(css);
 const collator=new Intl.Collator(undefined,{numeric:true,sensitivity:"base"});
 const empty=v=>v==null||v==="";
 function compare(a,b){if(Array.isArray(a)&&Array.isArray(b)){for(let i=0;i<Math.max(a.length,b.length);i++){const n=compare(a[i],b[i]);if(n)return n}return 0}if(empty(a)||empty(b))return empty(a)===empty(b)?0:empty(a)?1:-1;return typeof a==="number"&&typeof b==="number"?a-b:collator.compare(String(a),String(b))}
 window.createTableSort=(table,getValue,onChange,initialKey)=>{
  let key=initialKey,direction=1;
  const headers=[...table.querySelectorAll("th[data-sort]")];
  const update=()=>headers.forEach(th=>{const active=th.dataset.sort===key;th.setAttribute("aria-sort",active?(direction===1?"ascending":"descending"):"none");th.querySelector(".table-sort-arrow").textContent=active?(direction===1?"▲":"▼"):"↕"});
  headers.forEach(th=>{const label=th.textContent,button=document.createElement("button"),arrow=document.createElement("span");button.type="button";button.className="table-sort-button";button.appendChild(document.createTextNode(label));arrow.className="table-sort-arrow";arrow.setAttribute("aria-hidden","true");button.appendChild(arrow);button.setAttribute("aria-label","Sort by "+label);th.textContent="";th.appendChild(button);button.addEventListener("click",()=>{if(key===th.dataset.sort)direction*=-1;else{key=th.dataset.sort;direction=1}update();onChange()})});
  update();
  return {sort(rows){return [...rows].sort((a,b)=>{const av=getValue(a,key),bv=getValue(b,key);if(empty(av)||empty(bv))return compare(av,bv);return direction*compare(av,bv)})}};
 };
})();
