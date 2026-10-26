const $=id=>document.getElementById(id);
let csrf='',work=null,node=null,loaded=null,pending=null,mode='',dirtyText=false,dirtyNotes=false;
const requests=new Map();
function requestToken(kind,payload){const signature=JSON.stringify(payload);const old=requests.get(kind);if(old?.signature===signature)return old.token;const token=crypto.randomUUID();requests.set(kind,{signature,token});return token}
const story={type:'Tipo de unidad (capÃ­tulo, escena, fragmento)',viewpoint:'Punto de vista',chronology:'Momento de la historia',objective:'FunciÃ³n narrativa',status:'Estado de revisiÃ³n'};
const academic={type:'Tipo de unidad (secciÃ³n, argumento, evidencia)',objective:'Pregunta u objetivo',status:'Estado de revisiÃ³n',evidence:'Evidencia y lÃ­mites',authors:'Autores',year:'AÃ±o',publication:'PublicaciÃ³n o editorial',doi:'DOI o URL',citation:'Cita en el texto',reference:'Referencia bibliogrÃ¡fica revisada (APA 7)'};
function status(text,error=false){$('status').textContent=text;$('status').className=error?'error':''}
async function api(path,data={}){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify(data)});const result=await r.json();if(!r.ok)throw Error(result.error||'Error de conexiÃ³n');return result}
async function run(job){document.querySelectorAll('button,select,input,textarea').forEach(b=>b.disabled=true);status('Procesandoâ€¦');try{await job()}catch(e){status(e.message,true)}finally{document.querySelectorAll('button,select,input,textarea').forEach(b=>b.disabled=false)}}
function option(select,value,label){const e=document.createElement('option');e.value=value;e.textContent=label;select.append(e)}
function canLeave(){return !(dirtyText||dirtyNotes)||confirm('Hay cambios sin guardar. Â¿Descartarlos para continuar?')}
async function init(){const s=await fetch('/api/session');csrf=(await s.json()).csrf;const data=await api('/api/init');mode=data.mode;$('template').replaceChildren();for(const [k,v] of Object.entries(mode==='historias'?{'':'Sin plantilla',story:'Novela',script:'Guion',series:'Serie'}:{'':'Sin plantilla',paper:'Paper',tfg:'TFG'}))option($('template'),k,v);$('brand').textContent=data.title;document.title=data.title;$('projects').replaceChildren();data.projects.forEach(p=>option($('projects'),p.identifier,p.name));fillWorks(data.works);$('format-note').textContent=mode==='academico'?'Las referencias APA 7 se registran y revisan aquÃ­. Esta versiÃ³n exporta el texto estructurado; todavÃ­a no aplica automÃ¡ticamente toda la maquetaciÃ³n APA ni las plantillas de cada universidad.':'La rama es una base narrativa comÃºn. La exportaciÃ³n no convierte automÃ¡ticamente la prosa en guion audiovisual.';status('Selecciona un trabajo.');}
function fillWorks(works){const selected=$('works').value;$('works').replaceChildren();option($('works'),'','Selecciona un trabajo');works.forEach(w=>option($('works'),w.id,w.title));$('works').value=selected;}
async function loadWork(key,selected){loaded=await api('/api/work',{work:key});work=loaded.work;pending=null;$('apply').hidden=true;$('diff').textContent='';$('tree').replaceChildren();for(const r of loaded.branch.records){const b=document.createElement('button');b.textContent='ã€€'.repeat(r.depth)+r.fields.subject;b.dataset.key=r.key;b.addEventListener('click',()=>{if(canLeave())selectNode(r.key)});$('tree').append(b)}$('editor').hidden=false;$('empty').hidden=true;selectNode(selected||loaded.branch.records[0].key);status(loaded.source_warning||(work.storage==='local'?'Instancia documental local; fuentes enlazadas al universo.':'Trabajo actualizado desde cosmoSys.'),!!loaded.source_warning);}
function selectNode(key){node=loaded.branch.records.find(r=>r.key===key)||loaded.branch.records[0];$('title').value=node.fields.subject;$('text').value=node.fields.description;$('identity').textContent=node.label;$('source').hidden=work.storage==='local';$('save-text').textContent=work.storage==='local'?'Guardar texto en la instancia':'Guardar texto en cosmoSys';$('source').href='http://localhost:3080/issues/'+node.key.split(':')[1];$('export').href='/export?work='+encodeURIComponent(work.id);$('export-node').href=$('export').href+'&node='+encodeURIComponent(node.key);$('metadata').replaceChildren();const notes=loaded.notes[node.key]?.data||{};for(const [key,label] of Object.entries(mode==='historias'?story:academic)){const l=document.createElement('label');l.textContent=label;const input=document.createElement('textarea');input.rows=['evidence','reference','objective'].includes(key)?3:1;input.dataset.field=key;input.value=notes[key]||'';input.addEventListener('input',()=>dirtyNotes=true);l.append(input);$('metadata').append(l)}$('sources').replaceChildren();for(const r of loaded.sources){option($('sources'),r.key,r.label+' â€” '+r.fields.subject)}for(const o of $('sources').options)o.selected=(notes.sources||[]).includes(o.value);$('source-links').replaceChildren();for(const key of notes.sources||[]){const r=loaded.sources.find(r=>r.key===key);if(!r)continue;const a=document.createElement('a');a.href='http://localhost:3080/issues/'+key.split(':')[1];a.textContent=r.fields.subject;a.target='_blank';a.rel='noreferrer';$('source-links').append(a,document.createElement('br'))}for(const b of $('tree').children)b.classList.toggle('active',b.dataset.key===node.key);dirtyText=false;dirtyNotes=false;}
$('title').addEventListener('input',()=>dirtyText=true);$('text').addEventListener('input',()=>dirtyText=true);$('sources').addEventListener('change',()=>dirtyNotes=true);window.addEventListener('beforeunload',e=>{if(dirtyText||dirtyNotes){e.preventDefault();e.returnValue=''}});
$('read').onclick=()=>run(async()=>{const data=await api('/api/project',{project:$('projects').value});$('roots').replaceChildren();option($('roots'),'','Crear una rama nueva');data.records.filter(r=>r.key.startsWith('issue:')).forEach(r=>option($('roots'),r.key,r.fields.subject));status('Selecciona la rama que representa la obra o trabajo.');});
$('connect').onclick=()=>run(async()=>{if(!canLeave())return;const payload={project:$('projects').value,root:$('roots').value,title:$('new-title').value,template:$('template').value};const w=await api('/api/connect',{...payload,token:requestToken('connect',payload)});const data=await api('/api/init');fillWorks(data.works);$('works').value=w.id;await loadWork(w.id);});
$('projects').onchange=()=>{$('roots').replaceChildren();option($('roots'),'','Crear una rama nueva');};
$('works').onchange=()=>{if($('works').value&&canLeave())run(()=>loadWork($('works').value));else $('works').value=work?.id||'';};
$('reload').onclick=()=>{if(work&&canLeave())run(()=>loadWork(work.id,node?.key));};
$('save-text').onclick=()=>run(async()=>{await api('/api/save-text',{work:work.id,node:node.key,revision:node.revision,before:{subject:node.fields.subject,description:node.fields.description},after:{subject:$('title').value,description:$('text').value}});node.fields.subject=$('title').value;node.fields.description=$('text').value;const fresh=await api('/api/work',{work:work.id});node.revision=fresh.branch.records.find(r=>r.key===node.key).revision;status(work.storage==='local'?'Texto guardado en la instancia acadÃ©mica. El universo no cambia.':'Texto guardado en cosmoSys. Las notas se guardan con su botÃ³n propio.');dirtyText=false;});
$('save-notes').onclick=()=>run(async()=>{const data={};document.querySelectorAll('[data-field]').forEach(e=>data[e.dataset.field]=e.value);data.sources=Array.from($('sources').selectedOptions).map(o=>o.value);const result=await api('/api/save-notes',{work:work.id,node:node.key,data,revision:loaded.notes[node.key]?.revision||0});loaded.notes[node.key]={data,revision:result.revision};status('Notas y referencias guardadas en este gestor.');dirtyNotes=false;});
$('add').onclick=()=>run(async()=>{if(!canLeave())return;const payload={work:work.id,parent:node.key,title:$('child-title').value};const r=await api('/api/node',{...payload,token:requestToken('node',payload)});requests.delete('node');$('child-title').value='';await loadWork(work.id,r.key);});
$('preview').onclick=()=>run(async()=>{const file=$('import-file').files[0];if(!file)throw Error('Selecciona un Word corregido.');if(file.size>15000000)throw Error('El Word supera los 15 MB.');const raw=new Uint8Array(await file.arrayBuffer());let binary='';for(let i=0;i<raw.length;i+=8192)binary+=String.fromCharCode(...raw.subarray(i,i+8192));const result=await api('/api/import-preview',{work:work.id,file:btoa(binary)});pending=result.token;$('diff').textContent=result.changes.map(c=>(c.create?'APARTADO NUEVO':'MODIFICACIÃ“N')+' Â· '+(c.after.subject||c.key)+'\n'+Object.entries(c.after).map(([k,v])=>k+'\nANTES: '+(c.before[k]||'')+'\nDESPUÃ‰S: '+v).join('\n')).join('\n\n')||'No hay cambios.';$('apply').hidden=!result.changes.length;status('Revisa todos los cambios antes de aplicarlos.');});
$('apply').onclick=()=>run(async()=>{if(!canLeave())return;const result=await api('/api/import-apply',{work:work.id,token:pending});await loadWork(work.id);status('ImportaciÃ³n confirmada: '+result.changed.length+' apartados.');});
// Academic publication settings belong to the instance, never to the universe.
let dirtyPublication=false;
const publicationFields={author:'Autor o autora',affiliation:'Departamento e instituciÃ³n',course:'Asignatura o titulaciÃ³n',instructor:'Tutor o tutora',due_date:'Fecha de entrega'};
const originalCanLeave=canLeave;
canLeave=()=>!dirtyPublication?originalCanLeave():confirm('Hay datos de portada sin guardar. Â¿Descartarlos?')&&originalCanLeave();
window.addEventListener('beforeunload',e=>{if(dirtyPublication){e.preventDefault();e.returnValue=''}});
const originalSelectNode=selectNode;
selectNode=function(key){
 originalSelectNode(key);
 if(mode!=='academico')return;
 const label=document.createElement('label');label.textContent='Uso en la exportaciÃ³n APA7';
 const select=document.createElement('select');select.dataset.field='export_role';
 for(const [key,text] of Object.entries({body:'Cuerpo',abstract:'Resumen sin sangrÃ­a',references:'Referencias con sangrÃ­a francesa',block_quote:'Cita en bloque',exclude:'No exportar este apartado ni sus hijos'}))option(select,key,text);
 select.value=loaded.notes[node.key]?.data?.export_role||'body';select.onchange=()=>dirtyNotes=true;
 label.append(select);$('metadata').append(label);
};
const originalLoadWork=loadWork;
loadWork=async function(key,selected){
 await originalLoadWork(key,selected);
 if(mode!=='academico')return;
 let panel=$('publication');
 if(!panel){
  panel=document.createElement('details');panel.id='publication';
  const summary=document.createElement('summary');summary.textContent='Portada y exportaciÃ³n APA7';panel.append(summary);
  for(const [key,text] of Object.entries(publicationFields)){
   const label=document.createElement('label');label.textContent=text;
   const input=document.createElement('input');input.id='publication-'+key;input.maxLength=1000;input.oninput=()=>dirtyPublication=true;label.append(input);panel.append(label);
  }
  const label=document.createElement('label');label.textContent='Tutor provisional';const provisional=document.createElement('input');provisional.type='checkbox';provisional.id='publication-provisional';provisional.onchange=()=>dirtyPublication=true;label.append(provisional);panel.append(label);
  const paper=document.createElement('select');paper.id='publication-paper';option(paper,'letter','Carta Â· APA');option(paper,'a4','A4 Â· si lo exige la universidad');paper.onchange=()=>dirtyPublication=true;panel.append(paper);
  const save=document.createElement('button');save.textContent='Guardar portada';save.onclick=()=>run(async()=>{
   const data={};for(const k of Object.keys(publicationFields))data[k]=$('publication-'+k).value;
   data.paper_size=paper.value;data.instructor_provisional=provisional.checked;
   const result=await api('/api/save-publication',{work:work.id,data,revision:loaded.notes.__publication__?.revision||0});
   loaded.notes.__publication__={data,revision:result.revision};dirtyPublication=false;status('Portada guardada en la instancia.');
  });panel.append(save);
  const download=document.createElement('button');download.textContent='Revisar y exportar Word APA7';download.onclick=()=>run(async()=>{
   if(dirtyText||dirtyNotes||dirtyPublication)throw Error('Guarda texto, notas y portada antes de exportar.');
   const result=await api('/api/export-check',{work:work.id});
   $('publication-check').textContent='Apartados excluidos: '+result.excluded+'\n'+result.warnings.join('\n');
   if(confirm('Revisa antes de entregar:\n'+result.warnings.join('\n')+'\n\nÂ¿Descargar el Word para revisiÃ³n?'))window.location.href='/export?work='+encodeURIComponent(work.id)+'&profile=apa7-student';
   status('RevisiÃ³n de exportaciÃ³n preparada.');
  });panel.append(download);
  const check=document.createElement('pre');check.id='publication-check';panel.append(check);$('editor').append(panel);
 }
 const data=loaded.notes.__publication__?.data||{};
 for(const key of Object.keys(publicationFields))$('publication-'+key).value=data[key]||'';
 $('publication-paper').value=data.paper_size||'letter';$('publication-provisional').checked=!!data.instructor_provisional;dirtyPublication=false;
 $('format-note').textContent='APA7 de estudiante: portada, paginaciÃ³n, tÃ­tulos y referencias. Revisa el contenido, las citas y los requisitos de la universidad. El Word devuelve las correcciones del texto a la instancia; la portada y referencias generadas se editan aquÃ­.';
};
const originalInit=init;
init=async function(){
 await originalInit();
 if(mode!=='academico')return;
 const button=document.createElement('button');button.textContent='Crear instancia TFG local';
 button.onclick=()=>run(async()=>{
  if(!canLeave())return;
  const payload={project:$('projects').value,source:$('roots').value,title:$('new-title').value};
  const result=await api('/api/create-instance',{...payload,token:requestToken('instance',payload)});
  const data=await api('/api/init');fillWorks(data.works);$('works').value=result.id;await loadWork(result.id);
 });$('connect').after(button);
};

run(async()=>{
 await init();
 if(mode==='academico'){
  const button=document.createElement('button');
  button.textContent='Exportar formato acadÃ©mico base (experimental)';
  button.onclick=()=>{
   if(!work)return;
   if(dirtyText||dirtyNotes){status('Guarda los cambios antes de exportar.',true);return;}
   window.location.href='/export?work='+encodeURIComponent(work.id)+'&profile=academic-base';
  };
  $('export-node').after(button);
  $('format-note').textContent='Formato acadÃ©mico base: Times New Roman 12, doble espacio, mÃ¡rgenes de 2,54 cm y sangrÃ­a inicial. Conserva el intercambio reversible. No es todavÃ­a un documento APA7 completo: faltan portada, paginaciÃ³n, formato completo de tÃ­tulos, referencias y requisitos de tu universidad.';
 }
});
