// The naming contract (tools/ml2hx/README.md). Shared by the emitter and the
// runtime checks; changing a rule here changes the contract.
export const keywords = new Set(('abstract break case cast catch class continue default do dynamic else enum extends extern false final for function if implements import in inline interface macro new null operator overload override package private public return static super switch this throw true try typedef untyped using var while').split(' '));
// Names Haxe resolves specially in expression position or that clash with
// generated members.
const reserved = new Set(['trace', 'init']);
const opChars = {'!':'Bang','$':'Dollar','%':'Percent','&':'Amp','*':'Star','+':'Plus','-':'Minus','.':'Dot','/':'Slash',':':'Colon','<':'Lt','=':'Eq','>':'Gt','?':'Qmark','@':'At','^':'Caret','|':'Bar','~':'Tilde','#':'Hash'};
export function isOperator(s) { return s.length > 0 && !/^[A-Za-z_]/.test(s); }
export function opName(s) {
  let out = 'op';
  for (const c of s) { if (!opChars[c]) throw new Error(`operator character ${c} in ${s}`); out += opChars[c]; }
  return out;
}
function camelCore(s) {
  return s.replace(/'/g, '_').replace(/_([a-z])/g, (_, c) => c.toUpperCase());
}
// OCaml value (or record field, method) name -> Haxe identifier.
export function valueName(s) {
  if (isOperator(s)) return opName(s);
  let v = camelCore(s);
  if (keywords.has(v) || reserved.has(v)) v += 'Value';
  return v;
}
export const camel = valueName;
// OCaml type name -> Haxe type name.
export function typeName(s) { const v = camelCore(s); return v[0].toUpperCase() + v.slice(1); }
// OCaml exception (extension constructor) name -> Haxe class name.
export function exnName(s) { return typeName(s) + 'Exn'; }
// Library unit name (Stdlib__List, Unix, Option) -> ml2hx.std class name.
const shadowsStdlib = {Option: 'Extlib_Option'};
export function libraryModule(unit) {
  if (unit.startsWith('Stdlib__')) return unit.slice(8);
  return shadowsStdlib[unit] ?? unit;
}
