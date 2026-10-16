(()=>{
 const theme=document.getElementById("themeToggle");theme.checked=document.documentElement.dataset.theme==="dark";
 const enabledKey="live-trailer-board-sound-enabled-v1",volumeKey="live-trailer-board-sound-volume-v1",toggle=document.getElementById("soundToggle"),volume=document.getElementById("soundVolume");let enabled=true,level=.5;
 function render(){toggle.textContent=enabled?"🔊 Sound On":"🔇 Sound Off";toggle.setAttribute("aria-pressed",String(enabled));volume.value=String(level)}
 try{enabled=localStorage.getItem(enabledKey)!=="false";const value=Number(localStorage.getItem(volumeKey));if([.25,.5,.75,1].includes(value))level=value}catch{}
 toggle.onclick=()=>{enabled=!enabled;try{localStorage.setItem(enabledKey,String(enabled))}catch{}render()};
 volume.onchange=()=>{level=Number(volume.value);try{localStorage.setItem(volumeKey,String(level))}catch{}};
 window.addEventListener("storage",e=>{if(e.key===enabledKey){enabled=e.newValue!=="false";render()}if(e.key===volumeKey){const value=Number(e.newValue);if([.25,.5,.75,1].includes(value))level=value;render()}});
 render();
})();
