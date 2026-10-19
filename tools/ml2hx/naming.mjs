// The naming contract (tools/ml2hx/README.md). Shared by the emitter and the
// runtime checks; changing a rule here changes the contract.
export const keywords = new Set(('abstract break case cast catch class continue default do dynamic else enum extends extern false final for function if implements import in inline interface macro new null operator overload override package private public return static super switch this throw true try typedef untyped using var while').split(' '));
// Names Haxe resolves specially in expression position or that clash with
// generated members.
const reserved = new Set(['trace']);
const opChars = {'!':'Bang','$':'Dollar','%':'Percent','&':'Amp','*':'Star','+':'Plus','-':'Minus','.':'Dot','/':'Slash',':':'Colon','<':'Lt','=':'Eq','>':'Gt','?':'Qmark','@':'At','^':'Caret','|':'Bar','~':'Tilde','#':'Hash'};
export function isOperator(s) { return s.length > 0 && !/^[A-Za-z_0-9]/.test(s); }
// Stdlib's operators have names (the runtime's); others are spelled out.
const opNames = {'+': 'opAdd', '-': 'opSub', '*': 'opMul', '/': 'opDiv', '~-': 'opNeg', '~+': 'opPos', '+.': 'opAddF', '-.': 'opSubF', '*.': 'opMulF', '/.': 'opDivF',
  '~-.': 'opNegF', '~+.': 'opPosF', '**': 'opPow', '=': 'opEq', '<>': 'opNe', '==': 'opPhysEq', '!=': 'opPhysNe', '<': 'opLt', '>': 'opGt', '<=': 'opLe', '>=': 'opGe',
  '&&': 'opAnd', '||': 'opOr', '^': 'opConcat', '@': 'opAppend', '!': 'opDeref', ':=': 'opAssign', '|>': 'opPipe', '@@': 'opApply'};
export function opName(s) {
  if (opNames[s]) return opNames[s];
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
  if (/^[0-9]/.test(v)) v = 'v' + v;
  if (keywords.has(v) || reserved.has(v)) v += 'Value';
  return v;
}
export const camel = valueName;
// OCaml type name -> Haxe type name.
export function typeName(s) { const v = camelCore(s); return v[0].toUpperCase() + v.slice(1); }
// A type (or exception) of module M -> its Haxe name: prefixed with the
// module's name, as Haxe type names are unique per package (Hashtbl.t ->
// HashtblT, Option.No_value -> OptionNoValue).
export function moduleTypeName(module, s) { return module.replace(/_/g, '') + typeName(s); }
export const exnName = typeName;
// OCaml's predefined exceptions are ml2hx.rt classes (constant ones raised as `.instance`).
export const predefExns = {Not_found: 'NotFound', Failure: 'Failure', Invalid_argument: 'InvalidArgument', End_of_file: 'EndOfFile',
  Division_by_zero: 'DivisionByZero', Sys_error: 'SysError', Match_failure: 'MatchFailure', Assert_failure: 'AssertFailure',
  Stack_overflow: 'StackOverflow', Out_of_memory: 'OutOfMemory', Sys_blocked_io: 'SysBlockedIo', Undefined_recursive_module: 'UndefinedRecursiveModule'};
// Library unit name (Stdlib__List, Unix, Option) -> ml2hx.std class name.
const shadowsStdlib = {};
export function libraryModule(unit) {
  if (unit.startsWith('Stdlib__')) return unit.slice(8);
  return shadowsStdlib[unit] ?? unit;
}
