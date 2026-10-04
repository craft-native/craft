(function(){'use strict';if(!window.craft)window.craft={};
function s(a,d){if(!window.webkit?.messageHandlers?.craft)throw new Error('Craft bridge not available');
window.webkit.messageHandlers.craft.postMessage({t:'nativeUI',a:a,d:d})}
// A native source list. setSections replaces everything (counts, rows that
// come and go) keeping the selection by id; updateItem changes one row in
// place. onSelect hears the person's picks only - setSelectedItem is silent.
class Sidebar{constructor(id){this.id=id;this._selectCallbacks=[];this._contextMenuCallbacks=[]}
addSection(section){s('addSidebarSection',{sidebarId:this.id,section:section});return this}
setSections(sections){s('setSidebarSections',{sidebarId:this.id,sections:sections||[]});return this}
updateItem(itemId,changes){s('updateSidebarItem',Object.assign({},changes||{},{sidebarId:this.id,itemId:itemId}));return this}
setSelectedItem(itemId){s('setSelectedItem',{sidebarId:this.id,itemId:itemId});return this}
onSelect(cb){if(typeof cb==='function')this._selectCallbacks.push(cb);return this}
_emit(itemId){for(const cb of this._selectCallbacks.slice()){try{cb(itemId)}catch(e){console.error('[craft] sidebar select listener threw',e)}}}
onContextMenu(cb){this._contextMenuCallbacks.push(cb);return this}
showContextMenu(o){s('showContextMenu',{targetId:o.itemId,targetType:'sidebar',x:o.x,y:o.y,items:o.items||[{id:'rename',title:'Rename...',icon:'pencil'},{id:'s1',title:'',type:'separator'},{id:'new_folder',title:'New Folder',icon:'folder.badge.plus',shortcut:'cmd+shift+n'},{id:'s2',title:'',type:'separator'},{id:'remove',title:'Remove from Sidebar',icon:'minus.circle'}]});return this}
destroy(){sidebarRegistry.delete(this.id);s('destroyComponent',{id:this.id,type:'sidebar'})}}
class FileBrowser{constructor(id){this.id=id;this._selectCallbacks=[];this._doubleClickCallbacks=[];this._contextMenuCallbacks=[]}
addFile(f){s('addFile',{browserId:this.id,file:f});return this}
addFiles(f){s('addFiles',{browserId:this.id,files:f});return this}
clearFiles(){s('clearFiles',{browserId:this.id});return this}
onSelect(cb){this._selectCallbacks.push(cb);return this}
onDoubleClick(cb){this._doubleClickCallbacks.push(cb);return this}
onContextMenu(cb){this._contextMenuCallbacks.push(cb);return this}
showContextMenu(o){s('showContextMenu',{targetId:o.fileId,targetType:'file',x:o.x,y:o.y,items:o.items||[{id:'open',title:'Open',icon:'arrow.up.forward.square',shortcut:'cmd+o'},{id:'open_with',title:'Open With...',icon:'arrow.up.forward.app'},{id:'s1',title:'',type:'separator'},{id:'get_info',title:'Get Info',icon:'info.circle',shortcut:'cmd+i'},{id:'rename',title:'Rename',icon:'pencil'},{id:'s2',title:'',type:'separator'},{id:'copy',title:'Copy',icon:'doc.on.doc',shortcut:'cmd+c'},{id:'duplicate',title:'Duplicate',icon:'plus.square.on.square',shortcut:'cmd+d'},{id:'s3',title:'',type:'separator'},{id:'move_to_trash',title:'Move to Trash',icon:'trash',shortcut:'cmd+delete'}]});return this}
previewFile(fid,fp,t){s('showQuickLook',{files:[{id:fid,path:fp,title:t}]});return this}
previewFiles(f,i=0){s('showQuickLook',{files:f,currentIndex:i});return this}
toggleQuickLook(f,i=0){s('toggleQuickLook',{files:f,currentIndex:i});return this}
destroy(){s('destroyComponent',{id:this.id,type:'fileBrowser'})}}
// Arc-style spaces. The webview keeps the spaces, their rows and the swipe;
// this only publishes the list to a native control in the window chrome and
// reports back what it selects. Callbacks are held here rather than native-side
// so `_emitSpaceChange` stays a plain function call the host can guard on.
class SpacesSidebar{constructor(id){this.id=id;this._spaceChangeCallbacks=[]}
onSpaceChange(cb){if(typeof cb==='function')this._spaceChangeCallbacks.push(cb);return this}
setSpaces(spaces){s('setSpaces',{id:this.id,spaces:spaces||[]});return this}
setActiveSpace(spaceId){s('setActiveSpace',{id:this.id,spaceId:spaceId});return this}
_emit(spaceId){for(const cb of this._spaceChangeCallbacks.slice()){try{cb(spaceId)}catch(e){console.error('[craft] spaceChange listener threw',e)}}}
destroy(){s('destroyComponent',{id:this.id,type:'spacesSidebar'})}}
class SplitView{constructor(id,sb,br){this.id=id;this.sidebar=sb;this.browser=br}
setDividerPosition(p){s('setDividerPosition',{splitViewId:this.id,position:p});return this}
destroy(){s('destroyComponent',{id:this.id,type:'splitView'})}}
const spacesRegistry=new Map();
const sidebarRegistry=new Map();
window.craft.nativeUI={
createSidebar(o={}){const id=o.id||`sidebar-${Date.now()}-${Math.random().toString(36).substr(2,9)}`;const h=new Sidebar(id);sidebarRegistry.set(id,h);s('createSidebar',Object.assign({},o,{id}));return h},
// Called by the host when the person picks a row. Late events after destroy() are ignored.
_emitSidebarSelect(id,itemId){const h=sidebarRegistry.get(id);if(h)h._emit(itemId)},
createSpacesSidebar(o={}){const id=o.id||`spaces-${Date.now()}-${Math.random().toString(36).substr(2,9)}`;const h=new SpacesSidebar(id);spacesRegistry.set(id,h);s('createSpacesSidebar',{id:id,spaces:o.spaces||[],activeSpace:o.activeSpace});const d=h.destroy.bind(h);h.destroy=()=>{spacesRegistry.delete(id);d()};return h},
// Called by the host when the native control is clicked. Unknown ids are
// ignored rather than thrown on: a late event after destroy() is expected.
_emitSpaceChange(id,spaceId){const h=spacesRegistry.get(id);if(h)h._emit(spaceId)},
createFileBrowser(o={}){const id=o.id||`browser-${Date.now()}-${Math.random().toString(36).substr(2,9)}`;s('createFileBrowser',{id});return new FileBrowser(id)},
createSplitView(o){if(!o.sidebar||!o.browser)throw new Error('createSplitView requires both sidebar and browser options');const id=o.id||`splitview-${Date.now()}-${Math.random().toString(36).substr(2,9)}`;s('createSplitView',{id:id,sidebarId:o.sidebar.id,browserId:o.browser.id});return new SplitView(id,o.sidebar,o.browser)},
// Resolves with {id,targetId,targetType} once the menu closes; id is null
// when it was dismissed. x/y are the event's clientX/clientY.
showContextMenu(o){if(!o.items||!o.items.length)throw new Error('showContextMenu requires items array');const d={targetId:o.targetId||'',targetType:o.targetType||'general',x:o.x||0,y:o.y||0,items:o.items};if(typeof window.craft.invoke==='function')return window.craft.invoke('nativeUI.showContextMenu',d);s('showContextMenu',d);return Promise.resolve({id:null,targetId:d.targetId,targetType:d.targetType})},
// Every context menu's outcome, whoever opened it. Returns an unsubscribe.
onContextMenuAction(cb){const h=e=>cb(e.detail||{});window.addEventListener('craft:contextmenu:action',h);return()=>window.removeEventListener('craft:contextmenu:action',h)},
showQuickLook(o){if(!o.files||!o.files.length)throw new Error('showQuickLook requires files array');s('showQuickLook',{files:o.files,currentIndex:o.currentIndex||0})},
closeQuickLook(){s('closeQuickLook',{})},
toggleQuickLook(o){if(!o.files||!o.files.length)throw new Error('toggleQuickLook requires files array');s('toggleQuickLook',{files:o.files,currentIndex:o.currentIndex||0})},
previewFile(fp,t){this.showQuickLook({files:[{id:fp,path:fp,title:t}]})}};
window.craft.components=window.craft.components||window.craft.nativeUI;
document.dispatchEvent(new CustomEvent('craft:nativeui:ready'))})();
