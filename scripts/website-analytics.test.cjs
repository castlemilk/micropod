const { test } = require('node:test');
const assert = require('node:assert/strict');
const { eligible, boot } = require('../landing/analytics.js');
const config = { enabled: true, origin: 'https://site.example', gaMeasurementId: 'G-TEST123', gaPrivacyReviewed: true };
function fixture(options = {}) {
  const elements = [];
  function element(tag) { const e = { tag, listeners: {}, children: [], setAttribute() {}, append(...nodes) {this.children.push(...nodes);}, addEventListener(name, fn) {this.listeners[name] = fn;}, click() {this.listeners.click();} }; elements.push(e); return e; }
  const doc = { createElement: element, getElementById(id) { return elements.find(e => e.id === id); }, body: element('body'), head: element('head'), addEventListener() {} };
  const saved = new Map(options.saved ? [['micropod-website-analytics-v1',options.saved]] : []);
  const win = { location: {origin:config.origin, pathname:'/micropod/', search:'', hash:'', reload() {win.reloaded=true;}}, navigator:{}, sessionStorage: {getItem:k=>saved.get(k),setItem:(k,v)=>saved.set(k,v),removeItem:k=>saved.delete(k)} };
  return {win,doc,elements,saved};
}
test('fails closed for config, privacy signals, host, route, query and hash', () => {
  const {win} = fixture();
  assert.equal(eligible(config,win.location,win.navigator),true);
  for (const patch of [{enabled:false},{gaPrivacyReviewed:false},{gaMeasurementId:''},{origin:''}]) assert.equal(!!eligible({...config,...patch},win.location,{}),false);
  for (const patch of [{origin:'https://other.example'},{pathname:'/library.html'},{search:'?email=x'},{hash:'#secret'}]) assert.equal(!!eligible(config,{...win.location,...patch},{}),false);
  for (const n of [{doNotTrack:'1'},{globalPrivacyControl:true}]) assert.equal(eligible(config,win.location,n),false);
});
test('default configuration has no UI, scripts or writes', () => {
  const f=fixture();boot(f.win,f.doc,{});assert.equal(f.doc.head.children.length,0);assert.equal(f.doc.body.children.length,0);assert.equal(f.saved.size,0);
});
test('reject sends nothing, explicit opt-in loads once, withdrawal disables before reload', () => {
  const f=fixture();boot(f.win,f.doc,config);
  const buttons=f.elements.filter(e=>e.tag==='button');buttons[1].click();
  assert.equal(f.doc.head.children.length,0);
  buttons[0].click();buttons[0].click();assert.equal(f.doc.head.children.length,1);assert.equal(f.win['ga-disable-G-TEST123'],false);
  const events=f.win.dataLayer.map(x=>Array.from(x));
  assert.equal(events.filter(e=>e[0]==='event'&&e[1]==='page_view').length,1);
  assert.equal(events.find(e=>e[0]==='config')[2].page_referrer,'');
  assert.equal(events.find(e=>e[0]==='config')[2].cookie_prefix,'micropod');
  assert.equal(events.find(e=>e[0]==='config')[2].cookie_path,'/micropod/');
  buttons[1].click();assert.equal(f.win['ga-disable-G-TEST123'],true);assert.equal(f.win.reloaded,true);assert.equal(f.saved.get('micropod-website-analytics-v1'),'denied');
});
test('denial survives reload; accepted session remains gated by GPC', () => {
  const denied=fixture({saved:'denied'});boot(denied.win,denied.doc,config);assert.equal(denied.doc.head.children.length,0);
  const accepted=fixture({saved:'granted'});accepted.win.navigator.globalPrivacyControl=true;boot(accepted.win,accepted.doc,config);assert.equal(accepted.doc.head.children.length,0);
});
test('storage failure does not opt in', () => {
  const f=fixture();f.win.sessionStorage.getItem=()=>{throw Error('blocked');};boot(f.win,f.doc,config);assert.equal(f.doc.head.children.length,0);assert.equal(f.doc.body.children.length,0);
});

test('scope never includes sibling GitHub Pages projects', () => {
 const f=fixture();
 for (const pathname of ['/','/micropod','/another-project/','/micropod/api/']) assert.equal(eligible(config,{...f.win.location,pathname},{}),false);
 assert.equal(eligible(config,{...f.win.location,pathname:'/micropod/index.html'},{}),true);
});
test('failed denial write clears old grant, and total storage failure never reloads', () => {
  const f=fixture({saved:'granted'});boot(f.win,f.doc,config);f.win.sessionStorage.setItem=()=>{throw Error('blocked');};
  f.elements.filter(e=>e.tag==='button')[1].click();assert.equal(f.saved.has('micropod-website-analytics-v1'),false);assert.equal(f.win.reloaded,true);
  const g=fixture({saved:'granted'});boot(g.win,g.doc,config);g.win.sessionStorage.setItem=()=>{throw Error('blocked');};g.win.sessionStorage.removeItem=()=>{throw Error('blocked');};
  g.elements.filter(e=>e.tag==='button')[1].click();assert.equal(g.win['ga-disable-G-TEST123'],true);assert.equal(g.win.reloaded,undefined);
});
