(()=>{
 const canvas=document.createElement("canvas"),ctx=canvas.getContext("2d");if(!ctx)return;
 const originals=new WeakMap();let frame=0;
 const skipped=new Set(["SCRIPT","STYLE","TEXTAREA","INPUT","SELECT","OPTION","SVG","PATH"]);
 function availableWidth(el,style){let width=el.clientWidth;if(!width&&el.parentElement){el=el.parentElement;style=getComputedStyle(el);width=el.clientWidth}return Math.max(0,width-parseFloat(style.paddingLeft||0)-parseFloat(style.paddingRight||0))}
 function fit(){
  frame=0;
  const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT),elements=new Set();let node;
  while(node=walker.nextNode()){const el=node.parentElement;if(el&&node.textContent.trim()&&!skipped.has(el.tagName)&&!el.closest("svg,script,style,textarea,select,.yard-site-nav"))elements.add(el)}
  for(const el of elements){
   if(!el.getClientRects().length)continue;
   let original=originals.get(el);if(!original){original={fontSize:el.style.fontSize,fontPriority:el.style.getPropertyPriority("font-size"),letterSpacing:el.style.letterSpacing};originals.set(el,original)}
   if(original.fontSize)el.style.setProperty("font-size",original.fontSize,original.fontPriority);else el.style.removeProperty("font-size");
   el.style.letterSpacing=original.letterSpacing;
   const style=getComputedStyle(el),limit=style.maxWidth&&style.maxWidth.endsWith("px")?parseFloat(style.maxWidth):Infinity,width=Math.min(availableWidth(el,style),limit),size=parseFloat(style.fontSize);
   if(width<=0||!size)continue;
   ctx.font=[style.fontStyle,style.fontWeight,style.fontSize,style.fontFamily].join(" ");
   const text=[...el.childNodes].filter(n=>n.nodeType===Node.TEXT_NODE).map(n=>n.textContent).join(" ");
   const words=text.split(/\s+/).filter(Boolean),spacing=parseFloat(style.letterSpacing)||0;
   const widest=Math.max(0,...words.map(w=>ctx.measureText(w).width+Math.max(0,w.length-1)*spacing));
   if(widest>width){el.style.setProperty("font-size",(Math.floor(size*(width/Math.max(1,widest))*.98*100)/100)+"px","important");el.style.letterSpacing="normal"}
  }
  document.dispatchEvent(new Event("wordfit:complete"));
 }
 function schedule(){if(!frame)frame=requestAnimationFrame(fit)}
 new MutationObserver(schedule).observe(document.body,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:["class","hidden","open"]});
 if(typeof ResizeObserver!=="undefined"){const observer=new ResizeObserver(schedule);observer.observe(document.documentElement)}
 window.addEventListener("resize",schedule);window.addEventListener("load",schedule);document.addEventListener("toggle",schedule,true);
 document.fonts?.ready.then(schedule);schedule();
})();
