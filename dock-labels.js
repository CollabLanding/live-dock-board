(()=>{"use strict";const walls={56:"Wall 3",57:"Wall 2",58:"Wall 1"};window.DockLabels={
 number:(building,number)=>Number(building)===200&&walls[Number(number)]?walls[Number(number)]:String(number??""),
 position:(building,number)=>Number(building)===200&&walls[Number(number)]?35+(Number(number)-55)/10:Number(number)
};})();
function dockNumber(number,building){return window.DockLabels.number(building,number)}
function dockPosition(building,number){return window.DockLabels.position(building,number)}
