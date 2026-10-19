// Typed-tree IR (frontend protocol 2) -> Haxe. Unsupported constructs are
// errors, never Dynamic or stubs. The naming contract is in naming.mjs and
// tools/ml2hx/README.md.
import {valueName, typeName, exnName, libraryModule, isOperator, keywords, moduleTypeName, predefExns} from './naming.mjs';

const RT = 'ml2hx.rt.';
// Library functors: the argument's values (with their arities), the result's
// key type and type t.
const libFunctors = {
  'Map.Make': {key: 'key', t: 'MapT', values: [['compare', 2]]},
  'Set.Make': {key: 'elt', t: 'SetT', values: [['compare', 2]]},
  'Hashtbl.Make': {key: 'key', t: 'HashtblT', values: [['equal', 2], ['hash', 1]]},
};
const STD = 'ml2hx.std.';
const UNIT = `${RT}Unit.value`;
class NeedsInference extends Error {}
export class Unsupported extends Error {
  constructor(where, message) {
    const l = where?.l ?? where?.loc;
    super(`${Array.isArray(l) ? `${l[0]}:${l[1] + 1}: ` : ''}${message}`);
    this.name = 'Unsupported';
  }
}
const predefTypes = {int: 'Int', char: 'Int', string: 'String', bytes: 'haxe.io.Bytes', float: 'Float', bool: 'Bool', unit: `${RT}Unit`,
  exn: `${RT}MlException`, array: 'Array', list: `${RT}MlList`, option: `${RT}MlOption`, nativeint: 'Int', int32: 'haxe.Int32', int64: 'haxe.Int64',
  lazy_t: `${RT}Lazy`, floatarray: 'Array<Float>'};
// Library types the emitter owns the representation of.
// Library types the emitter owns, and abbreviations of predefined types.
const coreLibraryTypes = {'Stdlib.ref': `${RT}Ref`, 'Lazy.t': `${RT}Lazy`, 'CamlinternalLazy.t': `${RT}Lazy`, 'Stdlib.Lazy.t': `${RT}Lazy`,
  'String.t': 'String', 'Bytes.t': 'haxe.io.Bytes', 'Char.t': 'Int', 'Int32.t': 'haxe.Int32', 'Int64.t': 'haxe.Int64', 'Nativeint.t': 'Int',
  'Int.t': `${RT}Int63`, 'Bool.t': 'Bool', 'Float.t': 'Float', 'Unit.t': `${RT}Unit`, 'List.t': `${RT}MlList`, 'Option.t': `${RT}MlOption`,
  'Array.t': 'Array', 'Stdlib.int32': 'haxe.Int32', 'Stdlib.int64': 'haxe.Int64', 'Stdlib.Int32.t': 'haxe.Int32', 'Stdlib.Int64.t': 'haxe.Int64',
  'Uchar.t': `${RT}Int63`, 'Uchar.utf_decode': `${RT}Int63`, 'Signed.Int64.t': 'haxe.Int64', 'Signed.Int32.t': 'haxe.Int32'};


// ---------------------------------------------------------------- paths
export function pathName(p) {
  if (p.p) return p.p;
  if (p.g) return p.g;
  if (p.l) return p.l.replace(/_\d+$/, '');
  if (p.d) return `${pathName(p.d[0])}.${p.d[1]}`;
  if (p.a) return `${pathName(p.a[0])}(${pathName(p.a[1])})`;
  return '?';
}
const lastName = p => p.d ? p.d[1] : pathName(p);
const identName = id => id.replace(/_\d+$/, '');
function libraryPath(p) {
  // [unit, ...submodules] for a library module path, or null.
  if (p.g) return [p.g];
  if (p.d) { const parent = libraryPath(p.d[0]); return parent ? [...parent, p.d[1]] : null; }
  return null;
}

// ---------------------------------------------------------------- program
// Whole-program knowledge: every unit's top-level structure, the library
// values used (for the runtime's interface), and unit dependencies.
export class Program {
  constructor({units, int63 = true}) {
    this.int63 = int63;
    this.units = new Map(units.map(u => [u.modname, u]));
    this.libraryUses = new Map();  // ml2hx.std class -> Map(member -> signature)
  }
  unit(name) { return this.units.get(name); }
  structure(name) {
    const u = this.units.get(name);
    if (!u) return null;
    if (u.structureError) throw u.structureError;
    if (!u.structure) {
      if (u.building) throw new Unsupported(null, `cyclic unit structure ${name}`);
      u.building = true;
      try { u.structure = new UnitEmitter(this, u).declare(); }
      catch (e) { u.structureError = new Unsupported(null, `dependency ${u.config.source}: ${e.name === "Unsupported" ? e.message : e.stack.split("\n").slice(0, 3).join(" ")}`); throw u.structureError; }
      finally { u.building = false; }
    }
    return u.structure;
  }
  // Whether a type declared in another unit abbreviates a tuple.
  declIsTuple(d) {
    const u = this.units.get(d.unit);
    if (!u) return false;
    const ir = u.ir ??= stripNewtypes(u.load());
    let t = ir.types[d.decl.manifest];
    return t?.k === 'tuple';
  }
  useLibrary(cls, member, signature) {
    if (!this.libraryUses.has(cls)) this.libraryUses.set(cls, new Map());
    const m = this.libraryUses.get(cls);
    if (!m.has(member)) m.set(member, signature);
  }
  emit(name) {
    const u = this.units.get(name);
    const e = new UnitEmitter(this, u);
    return e.emit();
  }
}

// A static module (compilation unit or submodule) as the emitter sees it.
class Struct {
  constructor(hx, prefix) {
    this.kind = 'struct'; this.hx = hx; this.prefix = prefix;
    this.values = new Map(); this.types = new Map(); this.modules = new Map(); this.exns = new Map(); this.classes = new Map(); this.modtypes = new Map();
  }
}
class LibraryModule {
  constructor(path) {
    // Stdlib.Buffer is the library module Buffer.
    if (path.length > 1 && path[0] === 'Stdlib') path = path.slice(1);
    this.kind = 'lib'; this.path = path; this.name = [libraryModule(path[0]), ...path.slice(1)].join('_'); this.hx = STD + this.name; }
  typeHx(t) { return `${this.hx}.${moduleTypeName(this.name, t)}`; }
  exnHx(x) {
    if (this.name === 'Stdlib' && x === 'Exit') return `${RT}Exit`;
    if (this.name === 'Stdlib' && predefExns[x]) return `${RT}${predefExns[x]}`;
    return `${this.hx}.${moduleTypeName(this.name, x)}`;
  }
}

// ---------------------------------------------------------------- emitter
class UnitEmitter {
  constructor(program, unit) {
    this.p = program; this.u = unit; this.ir = stripNewtypes(unit.load());
    this.localTypes = new Map();
    this.T = this.ir.types;
    this.cfg = unit.config;
    this.cls = `${this.cfg.package}.${this.cfg.class}`;
    this.ids = new Map();       // local ident -> descriptor (values, modules, types, exns, classes)
    this.serial = 0;
    this.usedNames = new Set();
    this.decls = [];            // Haxe module-level declarations
    this.statics = [];          // static members of the unit class
    this.subclasses = new Map(); // sub-structure class name -> members
    this.init = [];             // statements of the init function, in order
    this.tvars = new Map();     // type var id -> Haxe type parameter
    this.deps = new Set();
  }
  // ------------------------------------------------------------ helpers
  fail(n, msg) { throw new Unsupported(n, msg); }
  temp(base = 't') { return `_${base}${this.serial++}`; }
  fresh(name) {
    let v = valueName(name.replace(/^_+/, '')).replace(/^[A-Z]/, c => c.toLowerCase());
    if (!/^[a-z]/.test(v)) v = 'v' + v;
    if (keywords.has(v)) v += 'Value';
    let candidate = v, i = 1;
    while (this.usedNames.has(candidate) || candidate === this.cfg.class) candidate = `${v}${i++}`;
    this.usedNames.add(candidate);
    return candidate;
  }
  t(i) { const t = this.T[i]; if (!t) this.fail(null, `missing type ${i}`); return t; }
  // Follow abbreviations we know (program typedefs are left to Haxe).
  arrows(i) {
    // Argument types and result of a function type, through all arrows.
    const args = []; let t = this.t(i);
    while (t.k === 'poly') { i = t.body; t = this.t(i); }
    while (t.k === 'arrow') { args.push({label: t.label, t: t.arg}); i = t.res; t = this.t(i); while (t.k === 'poly') { i = t.body; t = this.t(i); } }
    return {args, res: i};
  }
  schemeArity(i) { let n = 0, t = this.t(i); while (t.k === 'arrow') { n++; t = this.t(t.res); } return n; }
  isPredef(i, name) { const t = this.t(i); return t.k === 'constr' && t.path.p === name; }
  isUnit(i) { return this.isPredef(i, 'unit'); }
  isInt(i) { return this.isPredef(i, 'int'); }

  // ------------------------------------------------------------ resolution
  resolveModule(p, n) {
    if (p.g) {
      const s = this.p.structure(p.g);
      if (s) { this.deps.add(p.g); return s; }
      return new LibraryModule([p.g]);
    }
    if (p.l) { const d = this.ids.get(p.l); if (!d) this.fail(n, `unknown module ${pathName(p)}`); return this.moduleDesc(d, n); }
    if (p.d) {
      const parent = this.resolveModule(p.d[0], n);
      if (parent.kind === 'lib') return new LibraryModule([...parent.path, p.d[1]]);
      if (parent.kind === 'struct') {
        const m = parent.modules.get(p.d[1]);
        if (!m) this.fail(n, `unknown module ${pathName(p)}`);
        return this.moduleDesc(m, n);
      }
      if (parent.kind === 'libinstance') this.fail(n, `submodule of a functor instance ${pathName(p)}`);
    }
    if (p.a) {
      const fn = this.resolveModule(p.a[0], n);
      if (fn.kind === 'lib') return {kind: 'libapply', path: pathName(p)};
    }
    this.fail(n, `module path ${pathName(p)}`);
  }
  moduleDesc(d, n) {
    if (d.kind === 'alias') return this.resolveModule(d.path, n);
    return d;
  }
  // A value path -> descriptor.
  resolveValue(p, n) {
    if (p.l) { const d = this.ids.get(p.l); if (!d) this.fail(n, `unknown value ${pathName(p)}`); return d; }
    if (p.d) {
      const m = this.resolveModule(p.d[0], n), name = p.d[1];
      if (m.kind === 'lib') return {kind: 'lib', cls: m.hx, name, member: valueName(name), path: m.path};
      if (m.kind === 'struct') {
        const v = m.values.get(name);
        if (v) return v;
        for (const lib of m.libIncludes ?? []) return {kind: 'lib', cls: lib.hx, name, member: valueName(name), path: lib.path};
        this.fail(n, `unknown value ${pathName(p)}`);
      }
      if (m.kind === 'libinstance') return {kind: 'instance', obj: m.hx, name, member: valueName(name), instance: m};
      this.fail(n, `value of module ${m.kind}: ${pathName(p)}`);
    }
    this.fail(n, `value path ${pathName(p)}`);
  }
  resolveType(p, n) {
    if (p.p) return {hx: predefTypes[p.p] ?? this.fail(n, `predefined type ${p.p}`), predef: p.p};
    if (p.l) {
      const d = this.ids.get(p.l);
      if (d) return d;
      // (type a): a locally abstract type is a type parameter of its function.
      const lt = this.localTypes.get(identName(p.l));
      if (lt) return {tparam: lt};
      // A GADT existential ($0, $Pair_'a): never inspected, any type.
      if (p.l.startsWith('$')) return {tparam: 'Any'};
      this.fail(n, `unknown type ${pathName(p)}`);
    }
    if (p.d) {
      const key = pathName(p);
      const lib = libraryPath(p);
      if (lib && !this.p.unit(lib[0])) {
        const norm = [libraryModule(lib[0]), ...lib.slice(1)].join('.').replace(/^Stdlib\.(?=\w+\.)/, '');
        if (coreLibraryTypes[norm]) return {hx: coreLibraryTypes[norm]};
        const m = new LibraryModule(lib.slice(0, -1));
        return {hx: m.typeHx(lib.at(-1)), library: norm};
      }
      let parent;
      try { parent = this.resolveModule(p.d[0], n); }
      catch (e) {
        // t.C: the inline record of constructor C of type t.
        let owner = null;
        try { owner = this.resolveType(p.d[0], n); } catch (_) { throw e; }
        if (owner.decl) return {hx: `${owner.hx}_${p.d[1]}`, inline: true};
        throw e;
      }
      if (parent.kind === 'struct') {
        const t = parent.types.get(p.d[1]);
        if (t) return t;
        for (const lib of parent.libIncludes ?? []) return {hx: lib.typeHx(p.d[1]), library: key};
        this.fail(n, `unknown type ${key}`);
      }
      if (parent.kind === 'libinstance') return {instance: parent, name: p.d[1]};
      if (parent.kind === 'lib') return {hx: parent.typeHx(p.d[1]), library: key};
      this.fail(n, `type of module ${parent.kind}: ${key}`);
    }
    this.fail(n, `type path ${pathName(p)}`);
  }

  // ------------------------------------------------------------ types
  type(i, n) {
    const t = this.t(i);
    switch (t.k) {
      case 'var': {
        const v = this.tvars.get(t.id);
        if (v) return v;
        // An unconstrained variable no definition generalises: parametric
        // code never inspects such values. Where Haxe can infer the type
        // (local declarations, casts) the annotation is left out instead.
        if (this.strictVars) throw new NeedsInference();
        return 'Any';
      }
      case 'arrow': return `(${this.type(t.arg, n)}) -> (${this.type(t.res, n)})`;
      case 'tuple': {
        if (t.args.length > 12) this.fail(n, `tuple arity ${t.args.length}`);
        return `${RT}Tuple${t.args.length}<${t.args.map(a => this.type(a, n)).join(', ')}>`;
      }
      case 'poly': return this.type(t.body, n);
      case 'variant': return `${RT}PolyVariant`;
      case 'constr': {
        if (t.path.p === 'int') return `${RT}Int63`;
        if (t.path.p === 'array' && this.isPredef(t.args[0], 'float') && false) return 'Array<Float>';
        if (/(^|\.)format[46]?$/.test(pathName(t.path)) && /^(Stdlib|CamlinternalFormatBasics)\b/.test(pathName(t.path))) return `${RT}Fmt`;
        const d = this.resolveType(t.path, n);
        if (d.instance) return this.instanceType(d.instance, d.name, t.args, n);
        if (d.tparam) return d.tparam;
        if (d.abbrev !== undefined) return d.abbrev;
        const args = t.args.map(a => this.type(a, n));
        // A library abbreviation the runtime does not define: its expansion.
        if (d.library && t.exp !== undefined) return this.type(t.exp, n);
        if (d.library) this.p.useLibrary(d.hx.replace(/\.[^.]+$/, ''), `type ${d.hx.split('.').at(-1)}`, `${t.args.length} parameter(s)`);
        return d.hx + (args.length ? `<${args.join(', ')}>` : '');
      }
      case 'object': {
        if (t.class) {
          const d = this.resolveType(t.class, n);
          if (d.kind !== 'class') this.fail(n, `object type of ${pathName(t.class)}`);
          // #c carries the row variable first.
          let args = t.classArgs ?? [];
          if (args.length === d.decl.params.length + 1) args = args.slice(1);
          return d.hx + (args.length ? `<${args.map(a => this.type(a, n)).join(', ')}>` : '');
        }
        // A structural object type: an anonymous structure of methods (class
        // instances unify with it structurally).
        if (this.objDepth > 3) this.fail(n, 'recursive structural object type');
        this.objDepth = (this.objDepth ?? 0) + 1;
        try {
          return `{ ${t.fields.map(f => {
            const sig = this.methodSignature(f.t, this.methodArity(f.t), n);
            return `function ${valueName(f.name)}${sig.gen}(${sig.params}):${sig.res};`;
          }).join(' ')} }`;
        } finally { this.objDepth--; }
      }
      case 'package': this.fail(n, 'first-class module type');
    }
    this.fail(n, `type ${t.k}${t.text ? ': ' + t.text : ''}`);
  }
  instanceType(inst, name, args, n) {
    if (name === inst.keyName) return inst.keyType;
    if (name === 't') {
      const a = args.map(x => this.type(x, n));
      return `${inst.lib.hx}.${inst.spec.t}<${[inst.keyType, ...a].join(', ')}>`;
    }
    this.fail(n, `type ${name} of functor instance ${inst.functor}`);
  }
  // A record label's Haxe field ('a ref's contents is Ref.value).
  fieldName(lbl) { return lbl.name === 'contents' && /(^|\.)ref$/.test(pathName(lbl.type ?? {})) ? 'value' : valueName(lbl.name); }
  // Whether a type is a tuple, through abbreviations.
  isTupleType(i, depth = 0) {
    const t = this.t(i);
    if (t.k === 'tuple') return true;
    if (t.k !== 'constr' || depth > 20) return false;
    if (t.exp !== undefined) return this.isTupleType(t.exp, depth + 1);
    try {
      const d = this.resolveType(t.path, null);
      if (d.decl?.kind === 'abstract' && d.decl.manifest !== null && d.unit === this.u.modname) return this.isTupleType(d.decl.manifest, depth + 1);
      if (d.decl?.kind === 'abstract' && d.decl.manifest !== null) return this.p.declIsTuple(d);
    } catch (e) {}
    return false;
  }
  // The type, or null when it has variables Haxe should infer.
  typeOrNull(i, n) {
    const saved = this.strictVars;
    this.strictVars = true;
    try { return this.type(i, n); } catch (e) { if (e instanceof NeedsInference) return null; throw e; } finally { this.strictVars = saved; }
  }
  // Type variables of a type, in order of first occurrence.
  typeVars(i, out = [], seen = new Set()) {
    if (seen.has(i)) return out;
    seen.add(i);
    const t = this.t(i);
    if (t.k === 'var') { if (!out.includes(t.id)) out.push(t.id); return out; }
    for (const k of ['arg', 'res', 'body']) if (typeof t[k] === 'number') this.typeVars(t[k], out, seen);
    for (const a of t.args ?? []) if (typeof a === 'number') this.typeVars(a, out, seen);
    for (const f of t.fields ?? []) { if (typeof f.t === 'number') this.typeVars(f.t, out, seen); for (const a of f.args ?? []) this.typeVars(a, out, seen); }
    return out;
  }
  withTypeParams(vars, body) {
    const saved = new Map(this.tvars), names = [];
    for (const id of vars) {
      if (this.tvars.has(id)) continue;
      const name = `T${this.tvars.size}`;
      let candidate = name, i = 0;
      while ([...this.tvars.values()].includes(candidate)) candidate = `T${this.tvars.size + ++i}`;
      this.tvars.set(id, candidate); names.push(candidate);
    }
    try { return body(names); } finally { this.tvars = saved; }
  }
  withLocalTypes(names, body, reuse = null) {
    if (!names.length) return body([]);
    if (reuse && reuse.length === names.length) {
      // (type a) for the function's own type variable: the same parameter.
      const saved = new Map(this.localTypes);
      names.forEach((n, i) => this.localTypes.set(n, reuse[i]));
      try { return body([]); } finally { this.localTypes = saved; }
    }
    const saved = new Map(this.localTypes), out = [];
    const used = new Set(this.tvars.values());
    for (const n of names) { let k = this.tvars.size + out.length, c; do c = `T${k++}`; while (used.has(c)); used.add(c); this.localTypes.set(n, c); out.push(c); }
    try { return body(out); } finally { this.localTypes = saved; }
  }
  genericVars(i) { return this.typeVars(i).filter(id => { const t = this.T.find((x) => x?.k === 'var' && x.id === id); return t?.gen && !this.tvars.has(id); }); }

  // ------------------------------------------------------------ declarations (pass 1)
  declare() {
    const s = new Struct(this.cls, `${this.cls}.`);
    this.root = s;
    this.declareItems(this.ir.items, s, []);
    return s;
  }
  declareItems(items, s, path) {
    for (const item of items) this.declareItem(item, s, path);
  }
  staticName(s, name) {
    s.staticNames ??= new Set();
    let v = valueName(name), c = v, i = 1;
    while (s.staticNames.has(c)) c = `${v}_${i++}`;
    s.staticNames.add(c);
    return c;
  }
  typeDeclName(path, name) {
    // Unique per package: prefixed with the unit's (and submodules') names.
    return moduleTypeName([this.cfg.module, ...path].join(''), name);
  }
  declareItem(item, s, path) {
    switch (item.k) {
      case 'value':
        for (const b of item.bindings) {
          for (const v of patternVars(b.p)) {
            const fn = b.p.k === 'var' && b.e.k === 'fun' ? funInfo(b.e) : null;
            const name = identName(v.id);
            // let f = g (an alias of a value): references go to g.
            if (b.p.k === 'var' && b.e.k === 'ident' && !item.rec) {
              let target = null;
              try { target = this.identDesc(b.e); } catch (e) {}
              if (target && ['static', 'lib', 'prim', 'external', 'instance', 'polystatic'].includes(target.kind)) {
                const alias = target.kind === 'lib' || target.kind === 'instance' ? {...target, scheme: b.e.scheme, aliasType: b.e.t} : target;
                s.values.set(name, alias); this.ids.set(v.id, alias); b.alias = true;
                continue;
              }
            }
            const hx = this.staticName(s, name);
            const d = fn ? {kind: 'static', hx: `${s.hx}.${hx}`, member: hx, arity: fn.arity, fn} : {kind: 'static', hx: `${s.hx}.${hx}`, member: hx, arity: 0};
            if (!fn && b.p.k === 'var' && this.genericVarsOfValue(b.p.t).length) { d.poly = true; d.kind = 'polystatic'; }
            s.values.set(name, d); this.ids.set(v.id, d);
          }
        }
        break;
      case 'external': {
        const name = item.name, hx = this.staticName(s, name);
        const d = item.prim && item.prim.name.startsWith('%') ? {kind: 'prim', prim: item.prim.name, arity: item.prim.arity}
          : {kind: 'external', cname: item.prim?.name, hx: `${s.hx}.${hx}`, member: hx, arity: item.prim?.arity ?? 0};
        s.values.set(name, d); this.ids.set(item.id, d);
        break;
      }
      case 'type':
        for (const d of item.decls) {
          const hx = `${this.cfg.package}.${this.cfg.class}.${this.typeDeclName(path, d.name)}`;
          const desc = {hx, decl: d, unit: this.u.modname};
          s.types.set(d.name, desc); this.ids.set(d.id, desc);
        }
        break;
      case 'exception': {
        const x = item.ext;
        const desc = x.rebind ? {kind: 'exnalias', path: x.rebind} : {hx: `${this.cfg.package}.${this.cfg.class}.${this.typeDeclName(path, x.name)}Exn`, ext: x, qualified: [this.u.modname, ...path, x.name].join('.')};
        s.exns.set(x.name, desc); this.ids.set(x.id, desc);
        break;
      }
      case 'typext':
        for (const x of item.ctors) {
          const desc = x.rebind ? {kind: 'exnalias', path: x.rebind} : {hx: `${this.cfg.package}.${this.cfg.class}.${this.typeDeclName(path, x.name)}Exn`, ext: x, qualified: [this.u.modname, ...path, x.name].join('.')};
          s.exns.set(x.name, desc); this.ids.set(x.id, desc);
        }
        break;
      case 'module': {
        if (!item.name || !item.id) break;
        const d = this.declareModule(item.m, [...path, item.name], s);
        s.modules.set(item.name, d); this.ids.set(item.id, d);
        break;
      }
      case 'recmodule': this.fail(item, 'recursive modules');
      case 'modtype': s.modtypes.set(item.name, item.mty); this.ids.set(item.id, {kind: 'modtype', mty: item.mty}); break;
      case 'include': {
        let m = this.declareModule(item.m, path, s, true);
        if (m.kind === 'alias') m = this.moduleDesc(m, item);
        if (m.kind === 'struct') {
          for (const [k, v] of m.values) s.values.set(k, v);
          for (const [k, v] of m.types) s.types.set(k, v);
          for (const [k, v] of m.modules) s.modules.set(k, v);
          for (const [k, v] of m.exns) s.exns.set(k, v);
          for (const [k, v] of m.classes) s.classes.set(k, v);
        } else if (m.kind === 'lib') {
          // include Buffer: the library module's members, unless redefined.
          (s.libIncludes ??= []).push(m);
        } else this.fail(item, `include of ${m.kind}`);
        // The signature's identifiers name the included items locally.
        for (const it of m.kind === 'struct' ? item.sig : []) {
          const name = identName(it.id);
          const d = it.k === 'value' ? m.values.get(name) : it.k === 'type' ? m.types.get(name) : it.k === 'module' ? m.modules.get(name) : it.k === 'typext' ? m.exns.get(name) : it.k === 'class' ? m.classes.get(name) : null;
          if (d) this.ids.set(it.id, d);
        }
        if (m.kind === 'lib') for (const it of item.sig) {
          const name = identName(it.id);
          if (it.k === 'value') {
            // Members of an included library module keep its calling convention.
            const d = {kind: 'lib', cls: m.hx, name, member: valueName(name), path: m.path};
            if (it.prim && it.prim.name.startsWith('%')) Object.assign(d, {kind: 'prim', prim: it.prim.name, arity: it.prim.arity});
            if (!s.values.has(name)) s.values.set(name, d);
            this.ids.set(it.id, d);
          } else if (it.k === 'type') {
            const d = this.resolveType({d: [m.path.slice(1).reduce((p, x) => ({d: [p, x]}), {g: m.path[0]}), name]}, item);
            this.ids.set(it.id, d);
            if (!s.types.has(name)) s.types.set(name, d);
          } else if (it.k === 'typext') this.ids.set(it.id, {kind: 'exnalias', path: {d: [m.path.slice(1).reduce((p, x) => ({d: [p, x]}), {g: m.path[0]}), name]}});
        }
        break;
      }
      case 'class':
        for (const c of item.classes) {
          const hx = `${this.cfg.package}.${this.cfg.class}.${this.typeDeclName(path, c.name)}`;
          const d = this.declareClass(c, hx);
          s.classes.set(c.name, d); this.ids.set(c.id, d); this.ids.set(c.type, d); if (c.object) this.ids.set(c.object, d);
          s.types.set(c.name, d);
        }
        break;
      case 'eval': case 'open': case 'attribute': case 'classtype': break;
      default: this.fail(item, `structure item ${item.k}`);
    }
  }
  genericVarsOfValue(t) { return this.typeVars(t).filter(id => this.T.some(x => x?.k === 'var' && x.id === id && x.gen)); }
  declareModule(m, path, parent, included = false) {
    switch (m.k) {
      case 'ident': return {kind: 'alias', path: m.path};
      case 'constraint': return this.declareModule(m.m, path, parent, included);
      case 'struct': {
        const s = included ? new Struct(parent.hx, parent.prefix) : new Struct(`${this.cls}.${this.subName(path)}`, '');
        s.items = m.items; s.path = path; s.included = included;
        this.declareItems(m.items, s, path);
        return s;
      }
      case 'apply': {
        const fn = this.resolveModuleExpr(m.fn);
        if (fn.kind === 'lib') return this.declareLibInstance(fn, m, path, parent);
        if (fn.kind === 'functor') return this.instantiate(fn, m, path, parent);
        this.fail(m, `application of functor ${fn.kind}`);
      }
      // A functor: instantiated statically at each application (its body
      // emitted again with the parameter bound to the argument).
      case 'functor': return {kind: 'functor', node: m, unit: this.u.modname, emitter: this};
      case 'unpack': this.fail(m, 'first-class module unpacking');
    }
    this.fail(m, `module expression ${m.k}`);
  }
  // F(X) for a functor of the converted program: a static submodule, the
  // functor's body declared (and later emitted) with the parameter bound to
  // X. A functor of another unit is instantiated by an emitter of that unit
  // writing into this unit's output.
  instantiate(fn, m, path, parent) {
    let argExpr = m.arg;
    while (argExpr && argExpr.k === 'constraint') argExpr = argExpr.m;
    let arg = null;
    if (argExpr) {
      if (argExpr.k === 'struct') arg = this.declareModule(argExpr, [...path, 'Arg'], parent);
      else arg = this.resolveModuleExpr(argExpr);
    }
    let em = this;
    if (fn.unit !== this.u.modname) {
      em = new UnitEmitter(this.p, this.p.unit(fn.unit));
      em.declare();
      em.share(this);
    }
    const f = fn.node;
    if (f.param && arg) em.ids.set(f.param, arg);
    let body = f.body;
    while (body.k === 'constraint') body = body.m;
    if (body.k === 'functor') this.fail(m, 'curried functor');
    if (body.k !== 'struct') this.fail(m, `functor body ${body.k}`);
    const before = new Map(em.ids);
    const d = em.declareModule(body, path, parent);
    d.emitter = em;
    // This instance's identifiers (another application of the same functor
    // rebinds them): restored when the instance is emitted.
    d.idMap = new Map([...em.ids].filter(([k, v]) => before.get(k) !== v));
    if (f.param && arg) d.idMap.set(f.param, arg);
    return d;
  }
  // Write into another emitter's output (functor instances of other units).
  share(target) {
    this.cls = target.cls;
    this.cfg = target.cfg;
    this.decls = target.decls;
    this.statics = target.statics;
    this.subclasses = target.subclasses;
    this.init = target.init;
    this.root = target.root;
    this.usedNames = target.usedNames;
  }
  resolveModuleExpr(m) {
    if (m.k === 'ident') return this.resolveModule(m.path, m);
    if (m.k === 'constraint') return this.resolveModuleExpr(m.m);
    this.fail(m, `module expression ${m.k} in functor position`);
  }
  // Submodule classes are unique per package: prefixed with the unit's name.
  subName(path) { return [this.cfg.module, ...path].join('_'); }

  // ------------------------------------------------------------ emission (pass 2)
  emit() {
    const s = this.p.structure(this.u.modname);
    // Pass 1 ran on another emitter; replay the identifier table here.
    this.declare();
    this.emitItems(this.ir.items, this.root, []);
    const lines = [`package ${this.cfg.package};`, '', `// Generated by ml2hx from ${this.cfg.source}. Do not edit.`, ''];
    lines.push(...this.decls, '');
    lines.push(`class ${this.cfg.class} {`);
    lines.push(...this.statics.map(x => '\t' + x));
    lines.push(`\tpublic static function ml2hxInit():Void { ${this.init.join(' ')} }`);
    lines.push('}');
    for (const [name, members] of this.subclasses) lines.push('', `class ${name} {`, ...members.map(x => '\t' + x), '}');
    return {code: lines.join('\n') + '\n', deps: [...this.deps]};
  }
  emitItems(items, s, path) {
    for (const item of items) this.emitItem(item, s, path);
  }
  members(s) {
    if (s.hx === this.cls) return this.statics;
    const name = s.hx.slice(this.cls.length + 1);
    if (!this.subclasses.has(name)) this.subclasses.set(name, []);
    return this.subclasses.get(name);
  }
  emitItem(item, s, path) {
    switch (item.k) {
      case 'value': return this.emitTopValue(item, s);
      case 'eval': this.init.push(this.stmt(item.e)); return;
      case 'type': for (const d of item.decls) this.emitTypeDecl(d, s.types.get(d.name)); return;
      case 'exception': if (!item.ext.rebind) this.emitExtension(item.ext, s.exns.get(item.ext.name), `${RT}MlException`); return;
      case 'typext': {
        const base = this.resolveType(item.type, item);
        for (const x of item.ctors) if (!x.rebind) this.emitExtension(x, s.exns.get(x.name), base.hx);
        return;
      }
      case 'external': {
        const d = s.values.get(item.name);
        if (d.kind === 'external') {
          // C primitives of converted units are runtime functions.
          const {args, res} = this.arrows(item.t);
          this.withTypeParams(this.typeVars(item.t), params => {
            const names = args.map((_, i) => `a${i}`);
            const sig = `(${args.map((a, i) => `${names[i]}:${this.type(a.t, item)}`).join(', ')}):${this.type(res, item)}`;
            // ml2hx.prim.<Unit>: the unit's C primitives (README).
            const prim = `ml2hx.prim.${this.cfg.module}`;
            this.p.useLibrary(prim, valueName(item.prim.name), sig);
            this.members(s).push(`public static function ${d.member}${params.length ? `<${params.join(', ')}>` : ''}${sig} return ${prim}.${valueName(item.prim.name)}(${names.join(', ')});`);
          });
        }
        return;
      }
      case 'module': {
        if (!item.name || !item.id) return;
        const d = s.modules.get(item.name);
        if (d.kind === 'struct') {
          const em = d.emitter ?? this;
          for (const [k, v] of d.idMap ?? []) em.ids.set(k, v);
          em.emitItems(d.items, d, [...path, item.name]);
        }
        else if (d.kind === 'libinstance') this.emitLibInstance(d, item);
        return;
      }
      case 'include': {
        const m = item.m.k === 'constraint' ? item.m.m : item.m;
        if (m.k === 'struct') this.emitItems(m.items, s, path);
        return;
      }
      case 'class': for (const c of item.classes) this.emitClass(c, s.classes.get(c.name)); return;
      case 'open': if (item.m.k !== 'ident') this.fail(item, 'open of a structure'); return;
      case 'modtype': case 'attribute': case 'classtype': return;
    }
    this.fail(item, `structure item ${item.k}`);
  }
  // module M = F(X) for a library functor F: `ml2hx.std.Lib.F({...})`, an
  // instance whose methods are the result's values (README, Functors).
  declareLibInstance(fn, m, path, parent) {
    const functor = [libraryModule(fn.path[0]), ...fn.path.slice(1)].join('.');
    const spec = libFunctors[functor];
    if (!spec) this.fail(m, `library functor ${functor}`);
    let argExpr = m.arg;
    while (argExpr.k === 'constraint') argExpr = argExpr.m;
    let arg;
    if (argExpr.k === 'struct') {
      arg = this.declareModule(argExpr, [...path, 'Arg'], parent);
      arg.anonymous = true;
    } else arg = this.resolveModuleExpr(argExpr);
    let keyType;
    if (arg.kind === 'struct') {
      const t = arg.types.get('t');
      if (!t) this.fail(m, 'functor argument without type t');
      keyType = this.typeOfDecl(t, m);
    } else if (arg.kind === 'lib') keyType = this.resolveType({d: [arg.path.slice(1).reduce((p, x) => ({d: [p, x]}), {g: arg.path[0]}), 't']}, m).hx;
    else this.fail(m, `functor argument ${arg.kind}`);
    const lib = new LibraryModule(fn.path.slice(0, -1));
    return {kind: 'libinstance', functor, spec, arg, keyType, lib, keyName: spec.key, path,
      hx: `${this.cls}.${this.subName(path)}_instance`, cls: `${lib.hx}.${moduleTypeName(lib.name, fn.path.at(-1))}<${keyType}>`, call: `${lib.hx}.${fn.path.at(-1)}`};
  }
  emitLibInstance(d, item) {
    if (d.arg.anonymous) this.emitItems(d.arg.items, d.arg, [...d.path, 'Arg']);
    const fields = d.spec.values.map(([v, k]) => {
      let x;
      if (d.arg.kind === 'struct') { x = d.arg.values.get(v); if (!x) this.fail(item, `functor argument without ${v}`); }
      else x = {kind: 'lib', cls: d.arg.hx, name: v, member: valueName(v), path: d.arg.path, arity: k};
      const direct = (x.kind === 'static' || x.kind === 'lib') && (x.arity ?? k) === k ? (x.kind === 'lib' ? `${x.cls}.${x.member}` : x.hx) : null;
      if (direct) return `${v}: ${direct}`;
      if (x.kind === 'static' && x.arity === 0) {
        const ps = Array.from({length: k}, (_, i) => `_a${i}`);
        return `${v}: function(${ps.join(', ')}) return ${ps.reduce((a, p) => `${a}(${p})`, x.hx)}`;
      }
      this.fail(item, `functor argument value ${v}`);
    });
    const field = d.hx.split('.').at(-1);
    this.statics.push(`public static var ${field}:${d.cls};`);
    this.init.push(`${field} = ${d.call}({${fields.join(', ')}});`);
    this.p.useLibrary(d.lib.hx, `functor ${d.functor}`, '');
  }
  typeOfDecl(t, n) {
    if (t.decl?.manifest !== null && t.decl?.manifest !== undefined && t.decl.kind === 'abstract') return this.type(t.decl.manifest, n);
    return t.hx;
  }

  // ------------------------------------------------------------ type declarations
  declParams(d, n) {
    return d.params.map(p => { const t = this.t(p); if (t.k !== 'var') this.fail(n, 'constrained type parameter'); return t.id; });
  }
  emitTypeDecl(d, desc) {
    const name = desc.hx.split('.').at(-1);
    this.withTypeParams(this.declParams(d, d), params => {
      const gen = params.length ? `<${params.join(', ')}>` : '';
      if (d.kind === 'abstract') {
        if (d.manifest === null) {
          // An abstract type whose values only primitives make (`type zstream`
          // with C externals): an opaque class the runtime's primitives use.
          this.decls.push(`class ${name}${gen} {\n\tpublic function new() {}\n}`);
          return;
        }
        this.decls.push(`typedef ${name}${gen} = ${this.type(d.manifest, d)};`);
      } else if (d.kind === 'record') {
        this.decls.push(this.recordClass(name, gen, d.labels, d));
      } else if (d.kind === 'variant') {
        const ctors = d.ctors.map(c => {
          const render = () => {
            let args;
            if (c.args.record) {
              if (c.res !== null) this.fail(d, `GADT constructor ${c.name} with an inline record`);
              this.decls.push(this.recordClass(`${name}_${c.name}`, gen, c.args.record, d));
              args = [`v0:${name}_${c.name}${gen}`];
            } else args = c.args.tuple.map((a, i) => `v${i}:${this.type(a, d)}`);
            return {args, res: c.res !== null ? `:${this.type(c.res, d)}` : ''};
          };
          // A GADT constructor's variables are its own: constructor type parameters.
          const own = c.res !== null ? [...new Set([...c.args.tuple ?? [], c.res].flatMap(t => this.typeVars(t)))].filter(v => !this.tvars.has(v)) : [];
          return this.withTypeParams(own, ps => {
            const {args, res} = render();
            return `\t${c.name}${ps.length ? `<${ps.join(', ')}>` : ''}${args.length ? `(${args.join(', ')})` : ''}${res};`;
          });
        });
        this.decls.push(`enum ${name}${gen} {\n${ctors.join('\n')}\n}`);
      } else if (d.kind === 'open') {
        this.decls.push(`class ${name}${gen} {\n\tpublic function new() {}\n}`);
      } else this.fail(d, `type declaration ${d.kind}`);
    });
  }
  recordClass(name, gen, labels, n) {
    const fields = labels.map(l => ({name: valueName(l.name), mut: l.mut, t: this.type(l.t, n)}));
    return `class ${name}${gen} implements ${RT}Block {\n${fields.map(f => `\tpublic var ${f.name}:${f.t};`).join('\n')}\n\tpublic inline function new(${fields.map(f => `${f.name}:${f.t}`).join(', ')}) {\n${fields.map(f => `\t\tthis.${f.name} = ${f.name};`).join('\n')}\n\t}\n${blockMethods(fields.map(f => f.name))}\n}`;
  }
  emitExtension(x, desc, base) {
    const name = desc.hx.split('.').at(-1);
    if (x.res) this.fail(x, 'GADT extension constructor');
    if (x.args.record) this.fail(x, 'inline record in an extension constructor');
    this.withTypeParams(x.params.map(p => this.t(p)).filter(t => t.k === 'var').map(t => t.id), params => {
      if (params.length) this.fail(x, 'parameterised extensible type');
      const args = x.args.tuple.map((a, i) => ({name: `v${i}`, t: this.type(a, x)}));
      const isExn = base === `${RT}MlException`;
      const ctorArgs = args.map(a => `${a.name}:${a.t}`).join(', ');
      let extra = '';
      if (isExn) {
        extra = `\n\toverride public function exnName():String return ${JSON.stringify(desc.qualified)};\n\toverride public function exnArity():Int return ${args.length};`;
        if (args.length) extra += `\n\toverride public function exnArg(i:Int):Dynamic return switch i { ${args.map((a, i) => `case ${i}: ${a.name};`).join(' ')} case _: super.exnArg(i); };`;
        else extra += `\n\tpublic static final instance = new ${name}();`;
      }
      this.decls.push(`class ${name} extends ${base} {\n${args.map(a => `\tpublic final ${a.name}:${a.t};`).join('\n')}\n\tpublic function new(${ctorArgs}) {\n\t\tsuper();\n${args.map(a => `\t\tthis.${a.name} = ${a.name};`).join('\n')}\n\t}${extra}\n}`);
    });
  }

  // ------------------------------------------------------------ top-level values
  emitTopValue(item, s) {
    const members = this.members(s);
    if (item.rec && item.bindings.some(b => b.e.k !== 'fun')) this.fail(item, 'recursive non-function value');
    for (const b of item.bindings) {
      if (b.alias) continue;
      if (b.p.k === 'var' && b.e.k === 'fun') {
        const d = this.ids.get(b.p.id);
        const vars = this.typeVars(b.p.t).filter(v => !this.tvars.has(v));
        this.withTypeParams(vars, params0 => this.withLocalTypes(b.e.newtypes ?? [], lps => {
          const params = [...params0, ...lps];
          const f = this.functionParts(d.fn, {...b.e, t: b.e.newtypes ? b.p.t : b.e.t}, item.rec ? b.p.id : null);
          members.push(`public static function ${d.member}${params.length ? `<${params.join(', ')}>` : ''}(${f.params}):${f.res} ${f.body}`);
        }, params0));
        continue;
      }
      if (b.p.k === 'var') {
        const d = this.ids.get(b.p.id);
        if (d.poly) {
          const vars = this.genericVarsOfValue(b.p.t);
          const store = `${d.member}_`;
          const anyType = this.withTypeParams([], () => this.type(b.p.t, b));
          members.push(`public static var ${store}:${anyType};`);
          this.withTypeParams(vars, params => members.push(`public static inline function ${d.member}<${params.join(', ')}>():${this.type(b.p.t, b)} return cast ${store};`));
          this.init.push(`${s.hx === this.cls ? '' : s.hx + '.'}${store} = ${this.value(b.e)};`);
          continue;
        }
        members.push(`public static var ${d.member}:${this.type(b.p.t, b)};`);
        this.init.push(`${d.hx} = ${this.value(b.e)};`);
        continue;
      }
      // let () = e, let _ = e, let (a, b) = e: each variable is a static,
      // assigned by projection or by a match.
      const vars = patternVars(b.p);
      if (!vars.length && irrefutable(b.p)) { this.init.push(this.stmt(b.e)); continue; }
      for (const v of vars) { const d = this.ids.get(v.id); members.push(`public static var ${d.member}:${this.type(v.t, b)};`); }
      const saved = vars.map(v => [v.id, this.ids.get(v.id)]);
      const scrut = this.value(b.e);
      let code;
      if (irrefutable(b.p)) {
        const tmp = this.temp('d');
        code = `{ var ${tmp} = ${scrut}; ${this.bindIrrefutable(b.p, tmp)} ${vars.map((v, i) => `${saved[i][1].hx} = ${this.ids.get(v.id).name};`).join(' ')} }`;
      } else {
        const pat = this.pattern(b.p);
        code = `switch (${scrut}) { case ${pat.pat}${pat.guard ? ` if (${pat.guard})` : ''}: ${vars.map((v, i) => `${saved[i][1].hx} = ${this.ids.get(v.id).name};`).join(' ')} case _: throw ${this.matchFailure(b)}; }`;
      }
      for (const [id, d] of saved) this.ids.set(id, d);
      this.init.push(code);
    }
  }

  // ------------------------------------------------------------ functions
  // Parameters, result type and body of a known function (static or local).
  functionParts(fn, node, self) {
    const {args, res} = this.arrows(node.t);
    if (args.length < fn.arity) this.fail(node, 'function type has fewer arrows than parameters');
    const params = [], prologue = [];
    const savedIds = [];
    fn.params.forEach((p, i) => {
      const at = args[i].t;
      if (p.cases) {
        const name = this.fresh('param');
        params.push({name, t: at, cases: p.cases});
        return;
      }
      if (p.p.k === 'var' && !p.default) {
        const name = this.fresh(identName(p.p.id));
        savedIds.push([p.p.id, this.ids.get(p.p.id)]);
        this.ids.set(p.p.id, {kind: 'local', name});
        params.push({name, t: at});
        return;
      }
      const name = this.fresh(p.p.k === 'var' ? identName(p.p.id) : p.p.k === 'alias' ? identName(p.p.id) : 'arg');
      params.push({name, t: at, pattern: p.p, default: p.default, partial: p.partial});
    });
    const resType = fn.arity < args.length ? this.chainType(args.slice(fn.arity), res, node) : this.type(res, node);
    const tc = self ? {self, arity: fn.arity, slots: params.map(p => p.name), used: false} : null;
    // Destructuring parameters and the final `function` cases become one
    // match on the parameters, in order.
    let body = fn.body;
    const matches = [];
    for (const p of params) {
      if (p.default) {
        const inner = this.fresh(p.pattern.k === 'var' ? identName(p.pattern.id) : 'arg');
        prologue.push(`var ${inner}:${this.type(p.pattern.t, node)} = switch (${p.name}) { case ${RT}MlOption.Some(_x): _x; case ${RT}MlOption.None: ${this.value(p.default)}; };`);
        const direct = this.bindIrrefutable(p.pattern, inner);
        if (direct !== null) prologue.push(direct);
        else matches.push({scrut: inner, scrutType: p.pattern.t, cases: [{p: p.pattern, guard: null}], partial: p.partial});
      } else if (p.pattern) {
        const direct = this.bindIrrefutable(p.pattern, p.name);
        if (direct !== null) prologue.push(direct);
        else matches.push({scrut: p.name, scrutType: p.pattern.t, cases: [{p: p.pattern, guard: null}], partial: p.partial});
      }
      else if (p.cases) matches.push({scrut: p.name, scrutType: p.t, cases: p.cases.cases, partial: p.cases.partial, isCases: true, l: p.cases.l});
    }
    let code;
    if (tc) {
      // Self tail calls become a loop. Parameters are copied into fresh locals
      // per iteration so closures capture each iteration's values.
      const slots = params.map(p => p.name);
      const inner = slots.map(x => this.fresh(x));
      tc.slots = slots;
      const savedNames = params.map((p, i) => [p, inner[i]]);
      const rebinding = [];
      for (const [id, d] of [...fn.params.entries()].map(([i, p]) => [p.p?.id, i])) {}
      // Re-point parameter identifiers at the per-iteration copies.
      fn.params.forEach((p, i) => { if (p.p?.k === 'var' && !p.default) this.ids.set(p.p.id, {kind: 'local', name: inner[i]}); });
      const iterParams = params.map((p, i) => ({...p, name: inner[i]}));
      const bodyCode = this.functionBody(iterParams, matches.map(m => ({...m, scrut: inner[params.findIndex(p => p.name === m.scrut)] ?? m.scrut})), body, tc, prologue.map(x => x));
      code = `{ while (true) { ${params.map((p, i) => `var ${inner[i]} = ${p.name};`).join(' ')} ${bodyCode} } }`;
    } else code = `{ ${this.functionBody(params, matches, body, null, prologue)} }`;
    for (const [id, d] of savedIds) { if (d) this.ids.set(id, d); }
    return {params: params.map(p => `${p.name}:${this.type(p.t, node)}`).join(', '), res: resType, body: code};
  }
  // Bindings of an irrefutable pattern by projection, or null.
  bindIrrefutable(p, v) {
    switch (p.k) {
      case 'value': return this.bindIrrefutable(p.p, v);
      case 'any': return '';
      case 'var': { const name = this.fresh(identName(p.id)); this.ids.set(p.id, {kind: 'local', name}); return `var ${name} = ${v};`; }
      case 'alias': { const name = this.fresh(identName(p.id)); const inner = this.bindIrrefutable(p.p, name); if (inner === null) return null; this.ids.set(p.id, {kind: 'local', name}); return `var ${name} = ${v}; ${inner}`; }
      case 'construct': if (p.c.type?.p === 'unit') return ''; return null;
      case 'tuple': case 'record': {
        const subs = p.k === 'tuple' ? p.args.map((a, i) => [a, `v${i}`]) : p.fields.map(f => [f.p, this.fieldName(f.lbl)]);
        if (!subs.every(([a]) => irrefutable(a))) return null;
        const tmp = /^[\w]+$/.test(v) ? v : this.temp('d');
        let out = tmp === v ? '' : `var ${tmp} = ${v}; `;
        for (const [a, f] of subs) { const x = this.bindIrrefutable(a, `${tmp}.${f}`); if (x === null) return null; out += x + ' '; }
        return out;
      }
    }
    return null;
  }
  chainType(args, res, n) {
    let t = this.type(res, n);
    for (let i = args.length - 1; i >= 0; i--) t = `(${this.type(args[i].t, n)}) -> (${t})`;
    return t;
  }
  functionBody(params, matches, body, tc, prologue) {
    const pre = prologue.join(' ');
    if (!matches.length) return `${pre} ${this.ret(body, tc)}`;
    // Nest the matches; the innermost carries the body (or the cases).
    const build = (i) => {
      if (i === matches.length) return this.ret(body, tc);
      const m = matches[i];
      if (m.isCases) return this.matchStmt(m.scrut, m.scrutType, m.cases, m.partial, tc, m);
      return this.matchStmt(m.scrut, m.scrutType, m.cases.map(c => ({...c, e: {k: '$code', code: build(i + 1)}})), m.partial, tc, m, true);
    };
    return `${pre} ${build(0)}`;
  }
  // Statements that return the value of n (or continue a self tail call).
  ret(n, tc) {
    if (n.k === '$code') return n.code;
    switch (n.k) {
      case 'let': return `${this.bindings(n)} ${this.ret(n.body, tc)}`;
      case 'seq': return `${this.stmt(n.a)} ${this.ret(n.b, tc)}`;
      case 'if': return `if (${this.value(n.cond)}) { ${this.ret(n.then, tc)} } else { ${n.else ? this.ret(n.else, tc) : `return ${UNIT};`} }`;
      case 'match': return this.matchNode(n, tc, 'ret');
      case 'open': return this.ret(n.e, tc);
      case 'apply':
        if (tc && n.fn.k === 'ident' && n.fn.path.l === tc.self && n.args.length === tc.arity && n.args.every(a => a.e)) {
          tc.used = true;
          const temps = n.args.map(() => this.temp());
          return `${n.args.map((a, i) => `var ${temps[i]} = ${this.value(a.e)};`).reverse().join(' ')} ${tc.slots.map((s, i) => `${s} = ${temps[i]};`).join(' ')} continue;`;
        }
    }
    return `return ${this.value(n)};`;
  }

  // ------------------------------------------------------------ bindings
  bindings(n) {
    if (n.rec) return this.recBindings(n.bindings, n);
    // Non-recursive group: right-hand sides cannot see each other.
    const out = [];
    const pending = [];
    for (const b of n.bindings) {
      if (b.p.k === 'var' && b.e.k === 'fun') {
        const fn = funInfo(b.e);
        const name = this.fresh(identName(b.p.id));
        out.push(this.localFunction(name, fn, b.e, null, b.p.t));
        pending.push([b.p.id, {kind: 'localfn', name, arity: fn.arity}]);
      } else if (b.p.k === 'var' && pure(b.e) && this.genericVarsOfValue(b.p.t).some(v => !this.tvars.has(v))) {
        // A polymorphic local value (let empty = [] in ...): a syntactic
        // value, so it is emitted at each use with that use's type.
        pending.push([b.p.id, {kind: 'inline', node: b.e}]);
      } else if (b.p.k === 'var') {
        const name = this.fresh(identName(b.p.id));
        const t = this.typeOrNull(b.p.t, b);
        out.push(`var ${name}${t ? `:${t}` : ''} = ${this.value(b.e)};`);
        pending.push([b.p.id, {kind: 'local', name}]);
      } else if (b.p.k === 'any') {
        out.push(`${this.stmtValue(b.e)}`);
      } else if (b.p.k === 'construct' && b.p.c.name === '()' ) {
        out.push(this.stmt(b.e));
      } else {
        // Destructuring: projections when irrefutable, else a switch.
        const vars = patternVars(b.p);
        if (irrefutable(b.p)) {
          const tmp = this.temp('d');
          out.push(`var ${tmp} = ${this.value(b.e)};`);
          const saved = vars.map(v => [v.id, this.ids.get(v.id)]);
          out.push(this.bindIrrefutable(b.p, tmp));
          const bound = vars.map(v => this.ids.get(v.id));
          for (const [id, d] of saved) { if (d) this.ids.set(id, d); else this.ids.delete(id); }
          vars.forEach((v, i) => pending.push([v.id, bound[i]]));
          continue;
        }
        const names = vars.map(v => this.fresh(identName(v.id)));
        vars.forEach((v, i) => out.push(`var ${names[i]}:${this.type(v.t, b)};`));
        const saved = vars.map(v => [v.id, this.ids.get(v.id)]);
        const scrut = this.value(b.e);
        const pat = this.pattern(b.p);
        const caps = vars.map(v => this.ids.get(v.id).name);
        for (const [id, d] of saved) { if (d) this.ids.set(id, d); else this.ids.delete(id); }
        out.push(`switch (${scrut}) { case ${pat.pat}${pat.guard ? ` if (${pat.guard})` : ''}: ${names.map((x, i) => `${x} = ${caps[i]};`).join(' ')} case _: throw ${this.matchFailure(b)}; }`);
        vars.forEach((v, i) => pending.push([v.id, {kind: 'local', name: names[i]}]));
      }
    }
    for (const [id, d] of pending) this.ids.set(id, d);
    return out.join(' ');
  }
  recBindings(bs, n) {
    if (bs.some(b => b.p.k !== 'var')) this.fail(n, 'recursive binding of a pattern');
    if (bs.some(b => b.e.k !== 'fun')) return this.recValues(bs, n);
    if (bs.length === 1 && bs[0].e.k === 'fun') {
      const b = bs[0], fn = funInfo(b.e), name = this.fresh(identName(b.p.id));
      this.ids.set(b.p.id, {kind: 'localfn', name, arity: fn.arity});
      return this.localFunction(name, fn, b.e, b.p.id, b.p.t);
    }
    // Mutual recursion: variables of uncurried function types, assigned in
    // order (Haxe local functions cannot see later ones).
    const out = [];
    const infos = bs.map(b => {
      if (b.e.k !== 'fun') this.fail(b, 'recursive lazy binding');
      const fn = funInfo(b.e), name = this.fresh(identName(b.p.id));
      const {args, res} = this.arrows(b.e.t);
      const ft = `(${args.slice(0, fn.arity).map(a => this.type(a.t, b)).join(', ')}) -> ${fn.arity < args.length ? this.chainType(args.slice(fn.arity), res, b) : this.type(res, b)}`;
      out.push(`var ${name}:${ft} = null;`);
      this.ids.set(b.p.id, {kind: 'localfn', name, arity: fn.arity});
      return {b, fn, name};
    });
    for (const {b, fn, name} of infos) {
      const f = this.functionParts(fn, b.e, null);
      out.push(`${name} = function(${f.params}):${f.res} ${f.body};`);
    }
    return out.join(' ');
  }
  // let rec x = { ...; parent = x } (or lazy, or functions mixed in): the
  // variables first, then each value; a record field that is directly one of
  // the variables is patched after the record exists.
  recValues(bs, n) {
    const out = [], names = new Map();
    for (const b of bs) {
      const name = this.fresh(identName(b.p.id));
      names.set(b.p.id, name);
      out.push(`var ${name}:${this.type(b.p.t, b)} = null;`);
      if (b.e.k === 'fun') this.ids.set(b.p.id, {kind: 'local', name});
      else this.ids.set(b.p.id, {kind: 'local', name});
    }
    for (const b of bs) {
      const name = names.get(b.p.id);
      if (b.e.k === 'record' && !b.e.base) {
        const patches = [];
        const fields = b.e.fields.map(f => {
          if (f.e && f.e.k === 'ident' && f.e.path.l && names.has(f.e.path.l)) { patches.push([f.lbl, names.get(f.e.path.l)]); return {...f, e: {k: '$expr', code: 'null'}}; }
          return f;
        });
        out.push(`${name} = ${this.record({...b.e, fields})};`);
        for (const [lbl, v] of patches) out.push(`${name}.${this.fieldName(lbl)} = ${v};`);
      } else if (b.e.k === 'fun' || b.e.k === 'lazy' || b.e.k === 'construct' || b.e.k === 'record') out.push(`${name} = ${this.value(b.e)};`);
      else this.fail(b, `recursive value ${b.e.k}`);
    }
    return out.join(' ');
  }
  localFunction(name, fn, node, self, t) {
    const vars = this.typeVars(t).filter(v => !this.tvars.has(v) && this.T.some(x => x?.k === 'var' && x.id === v && x.gen));
    return this.withTypeParams(vars, params0 => this.withLocalTypes(node.newtypes ?? [], lps => {
      const params = [...params0, ...lps];
      const f = this.functionParts(fn, node, self);
      return `function ${name}${params.length ? `<${params.join(', ')}>` : ''}(${f.params}):${f.res} ${f.body}`;
    }));
  }
  // A function value (closure): curried.
  lambda(n) {
    const fn = funInfo(n);
    const {args, res} = this.arrows(n.t);
    const f = this.functionParts(fn, n, null);
    // functionParts gives an uncurried function; curry it.
    if (fn.arity === 1) return `function(${f.params}):${f.res} ${f.body}`;
    const tmp = this.fresh('f');
    const names = args.slice(0, fn.arity).map((_, i) => this.temp('a'));
    let call = `${tmp}(${names.join(', ')})`;
    let ty = f.res;
    for (let i = fn.arity - 1; i >= 0; i--) {
      call = `function(${names[i]}:${this.type(args[i].t, n)}):${ty} return ${call}`;
      ty = `(${this.type(args[i].t, n)}) -> (${ty})`;
    }
    return `{ function ${tmp}(${f.params}):${f.res} ${f.body}; ${call}; }`;
  }

  // ------------------------------------------------------------ expressions
  // Statement: evaluates n for effect.
  stmt(n) {
    switch (n.k) {
      case 'seq': return `${this.stmt(n.a)} ${this.stmt(n.b)}`;
      case 'let': return `{ ${this.bindings(n)} ${this.stmt(n.body)} }`;
      case 'if': return `if (${this.value(n.cond)}) { ${this.stmt(n.then)} }${n.else ? ` else { ${this.stmt(n.else)} }` : ''}`;
      case 'while': return `while (${this.value(n.cond)}) { ${this.stmt(n.body)} }`;
      case 'for': return this.forLoop(n);
      case 'setfield': return `${this.ordered([n.e, n.v], ([r, v]) => `${wrap(r)}.${this.fieldName(n.lbl)} = ${v}`)};`;
      case 'match': return this.matchNode(n, null, 'stmt');
      case 'open': return this.stmt(n.e);
      case 'construct': if (n.c.name === '()') return '';
      case 'const': case 'ident': return '';
      case 'apply': {
        const p = n.fn.k === 'ident' ? n.fn : null;
        if (p && p.prim?.name === '%ignore' && n.args.length === 1 && n.args[0].e) return this.stmtValue(n.args[0].e);
        if (p && (p.prim?.name === '%setfield0') && n.args.length === 2) return `${this.ordered([n.args[0].e, n.args[1].e], ([r, v]) => `${wrap(r)}.value = ${v}`)};`;
      }
    }
    return this.stmtValue(n);
  }
  stmtValue(n) {
    const v = this.value(n);
    return /^[A-Za-z_][\w.]*$/.test(v) ? '' : `${v};`;
  }
  // Expression with OCaml's value.
  value(n) {
    switch (n.k) {
      case '$code': return `{ ${n.code} }`;
      case '$expr': return n.code;
      case '$var': return n.name;
      case 'const': return this.constant(n.c, n);
      case 'ident': return this.identValue(n);
      case 'let': return `{ ${this.bindings(n)} ${this.value(n.body)}; }`;
      case 'seq': return `{ ${this.stmt(n.a)} ${this.value(n.b)}; }`;
      case 'if': {
        if (!n.else) return `{ ${this.stmt(n)} ${UNIT}; }`;
        return `(if (${this.value(n.cond)}) ${this.value(n.then)} else ${this.value(n.else)})`;
      }
      case 'while': case 'for': case 'setfield': return `{ ${this.stmt(n)} ${UNIT}; }`;
      case 'fun': return this.lambda(n);
      case 'apply': return this.apply(n);
      case 'match': return this.matchNode(n, null, 'value');
      case 'try': return this.tryExpr(n);
      case 'tuple': {
        const t = this.typeOrNull(n.t, n) ?? `${RT}Tuple${n.args.length}`;
        if (t.startsWith(`${RT}Tuple`)) return this.ordered(n.args, a => `new ${t}(${a.join(', ')})`);
        // A GADT-refined type (Haxe refines it in the branch too): the tuple's own type.
        const own = `${RT}Tuple${n.args.length}<${n.args.map(a => this.type(a.t, a)).join(', ')}>`;
        return this.ordered(n.args, a => `new ${own}(${a.join(', ')})`);
      }
      case 'construct': return this.construct(n);
      case 'variant': {
        const tag = JSON.stringify(n.tag), hash = hashVariant(n.tag);
        if (!n.arg) return `${RT}PolyVariant.constant(${hash}, ${tag})`;
        return `new ${RT}PolyVariant1(${hash}, ${tag}, ${this.value(n.arg)})`;
      }
      case 'record': return this.record(n);
      case 'field': return `${wrap(this.value(n.e))}.${this.fieldName(n.lbl)}`;
      case 'array': { const t = this.typeOrNull(n.t, n); return this.ordered(n.args, a => t ? `([${a.join(', ')}]:${t})` : `[${a.join(', ')}]`); }
      case 'assert': {
        const c = n.e;
        if (c.k === 'construct' && c.c.name === 'false') return `throw new ${RT}AssertFailure(${JSON.stringify(this.cfg.source)}, ${this.intLit(n.l[0])}, ${this.intLit(n.l[1])})`;
        return `{ if (!${this.value(c)}) throw new ${RT}AssertFailure(${JSON.stringify(this.cfg.source)}, ${this.intLit(n.l[0])}, ${this.intLit(n.l[1])}); ${UNIT}; }`;
      }
      case 'lazy': return `new ${RT}Lazy(function() return ${this.value(n.e)})`;
      case 'open': return this.value(n.e);
      case 'coerce': return this.value(n.e);
      case 'newtype': return this.withLocalType(n, () => this.value(n.e));
      case 'unreachable': return `throw ${this.matchFailure(n)}`;
      case 'letexception': this.fail(n, 'local exception');
      case 'letmodule': return this.letModule(n);
      case 'new': return this.newObject({k: 'apply', t: n.t, l: n.l, fn: n, args: []});
      case 'send': return this.send(n, []);
      case 'instvar': return `${this.selfName ?? 'this'}.${this.instvarField(n.name)}`;
      case 'setinstvar': return `{ ${this.selfName ?? 'this'}.${this.instvarField(n.name)} = ${this.value(n.v)}; ${UNIT}; }`;
      case 'object': return this.immediateObject(n);
      case 'override': this.fail(n, 'object copy {< >}');
      case 'pack': this.fail(n, 'first-class module');
      case 'unsupported': this.fail(n, n.text ?? 'unsupported expression');
    }
    this.fail(n, `expression ${n.k}`);
  }
  withLocalType(n, f) {
    // (type a) ...: locally abstract types act as type variables; the
    // frontend shows them as constructors of a local path.
    return f();
  }
  letModule(n) {
    const saved = this.ids.get(n.id);
    const s = new Struct(null, '');
    if (n.m.k === 'ident') this.ids.set(n.id, {kind: 'alias', path: n.m.path});
    else if (n.m.k === 'apply' || (n.m.k === 'constraint' && n.m.m.k === 'apply')) this.fail(n, 'local functor application');
    else this.fail(n, `local module ${n.m.k}`);
    const v = this.value(n.body);
    if (saved) this.ids.set(n.id, saved);
    return v;
  }
  // An OCaml int literal (63-bit) as an Int63.
  intLit(v) {
    const b = BigInt(v);
    if (b <= 0x7fffffffn && b >= -0x80000000n) return `${RT}Int63.ofInt(${b < 0n ? `(${v})` : v})`;
    return `${RT}Int63.parse(${JSON.stringify(String(v))})`;
  }
  constant(c, n) {
    switch (c.k) {
      case 'int': return this.intLit(c.v);
      case 'char': return String(c.v);
      case 'string': return haxeString(c.v);
      case 'float': {
        const x = c.v.replaceAll('_', '');
        if (/^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(x)) { const s = x.includes('.') || /[eE]/.test(x) ? x.replace(/\.$/, '.0').replace(/\.([eE])/, '.0$1') : `${x}.0`; return s.startsWith('-') ? `(${s})` : s; }
        if (/^-?0[xX]/.test(x)) { const v = Number.parseFloat(x); return String(v); }
        if (x === 'infinity') return 'Math.POSITIVE_INFINITY';
        if (x === 'nan') return 'Math.NaN';
        this.fail(n, `float literal ${x}`);
      }
      case 'int32': return `(${c.v}:haxe.Int32)`;
      case 'int64': return `haxe.Int64.parseString(${JSON.stringify(c.v)})`;
      case 'nativeint': return c.v;
    }
    this.fail(n, `constant ${c.k}`);
  }
  // Right-to-left evaluation of operands when two or more can have effects.
  ordered(nodes, build) {
    const impure = nodes.filter(x => !pure(x)).length;
    if (impure < 2) return build(nodes.map(x => this.value(x)));
    const names = nodes.map(() => this.temp());
    const vals = nodes.map(x => this.value(x));
    const decls = nodes.map((x, i) => pure(x) ? null : `var ${names[i]} = ${vals[i]};`).filter(Boolean).reverse().join(' ');
    return `{ ${decls} ${build(nodes.map((x, i) => pure(x) ? vals[i] : names[i]))}; }`;
  }
  identValue(n) {
    const d = this.identDesc(n);
    return this.valueRef(d, n, n);
  }
  identDesc(n) {
    if (n.prim && n.prim.name.startsWith('%') && this.primitives()[n.prim.name]) return {kind: 'prim', prim: n.prim.name, arity: n.prim.arity};
    return this.resolveValue(n.path, n);
  }
  // A reference to a value as a first-class value.
  valueRef(d, n, where) {
    switch (d.kind) {
      case 'local': return d.name;
      case 'inline': return this.value(d.node);
      case 'localfn': return this.curry(d.name, d.arity, n?.t, where);
      case 'static': return d.arity ? this.curry(d.hx, d.arity, n?.t, where) : d.hx;
      case 'polystatic': return `${d.hx}()`;
      case 'external': return d.arity ? this.curry(d.hx, d.arity, n?.t, where) : d.hx;
      case 'lib': {
        const arity = n ? this.schemeArity(n.scheme) : d.arity ?? 0;
        if (n) {
          // Printf.sprintf (and kin) as a value: the format as a value.
          const fake = {k: 'apply', t: n.t, l: n.l, fn: n, args: []};
          const fmtKind = {sprintf: 'sprintf', printf: 'printf', eprintf: 'eprintf'}[d.name];
          if (fmtKind && libraryModule(d.path[0]) === 'Printf') {
            const f = this.temp('fmt');
            const res = this.type(this.resultAfter(n.t, 1), n);
            return `(function(${f}:${RT}Fmt):${res} return (cast ${STD}Printf.curried(${f}, ${this.printfFinisher(fmtKind, [])}) : ${res}))`;
          }
        }
        this.useLib(d, n);
        if (d.name === 'raise' && false) return '';
        return arity ? this.libCall(`${d.cls}.${d.member}`, arity, {k: 'apply', args: [], t: n.t, l: n.l}, n) : `${d.cls}.${d.member}`;
      }
      case 'prim': return this.primValue(d, n, where);
      case 'instance': {
        const arity = n ? this.schemeArity(n.scheme) : 0;
        return arity ? this.libCall(`${d.obj}.${d.member}`, arity, {k: 'apply', args: [], t: n.t, l: n.l}, n) : `${d.obj}.${d.member}()`;
      }
      case 'exnalias': this.fail(where, 'exception alias used as a value');
    }
    this.fail(where, `value reference ${d.kind}`);
  }
  useLib(d, n) {
    if (!n) return;
    const sig = this.withTypeParams(this.typeVars(n.scheme).filter(v => !this.tvars.has(v)), params => {
      const {args, res} = this.arrows(n.scheme);
      try {
        return `${params.length ? `<${params.join(', ')}>` : ''}(${args.map((a, i) => `${a.label ? a.label.replace('?', 'opt_') : 'a' + i}:${this.type(a.t, n)}`).join(', ')}):${this.type(res, n)}`;
      } catch (e) { return `/* ${e.message} */`; }
    });
    this.p.useLibrary(d.cls, d.member, sig);
  }
  // Curried closure over a known n-ary function.
  curry(f, arity, t, where) {
    if (t === undefined) this.fail(where, 'function reference without a type');
    const {args, res} = this.arrows(t);
    if (args.length < arity) this.fail(where, `function value of arity ${arity} with ${args.length} arrows`);
    const names = args.slice(0, arity).map(() => this.temp('a'));
    let body = `${f}(${names.join(', ')})`;
    let ty = arity < args.length ? this.chainType(args.slice(arity), res, where) : this.type(res, where);
    for (let i = arity - 1; i >= 0; i--) {
      const at = this.type(args[i].t, where);
      body = `function(${names[i]}:${at}):${ty} return ${body}`;
      ty = `(${at}) -> (${ty})`;
    }
    return `(${body})`;
  }

  // ------------------------------------------------------------ application
  apply(n) {
    const fn = n.fn;
    if (fn.k === 'ident') {
      const d = this.identDesc(fn);
      if (d.kind === 'prim') {
        const r = this.primApply(d.prim, n, fn);
        if (r !== null) return r;
      }
      if (d.kind === 'lib') {
        const special = this.libApply(d, n, fn);
        if (special !== null) return special;
      }
      const arity = d.kind === 'lib' || d.kind === 'instance' ? this.schemeArity(fn.scheme) : d.arity ?? 0;
      if (d.kind === 'lib') this.useLib(d, fn);
      const callee = {local: null, localfn: d.name, static: d.hx, external: d.hx, lib: `${d.cls}.${d.member}`, instance: `${d.obj}.${d.member}`, polystatic: null, prim: null}[d.kind];
      if (callee && (d.kind === 'lib' || d.kind === 'instance')) return this.libCall(callee, arity, n, fn);
      if (callee && arity > 0) return this.knownCall(callee, arity, n, fn);
    }
    if (fn.k === 'new') return this.newObject(n);
    if (fn.k === 'send') return this.send(fn, n.args, n);
    // Unknown function value: curried application.
    if (n.args.some(a => !a.e)) return this.partialUnknown(n);
    const all = [...n.args.map(a => a.e), fn];
    return this.ordered(all, vals => {
      const f = vals.pop();
      return vals.reduce((acc, a) => `${acc}(${a})`, needsParens(f) ? `(${f})` : f);
    });
  }
  // Call a known function of the given arity with the application's args.
  // A library function: all arguments at once, function arguments uncurried
  // to the arity of the signature's arrows, optional arguments last as Haxe
  // optional arguments (README).
  libCall(callee, arity, n, fn) {
    const {args: scheme} = this.arrows(fn.scheme);
    const {args: formal, res} = this.arrows(fn.t);
    if (arity === 0) {
      // A constant (instance constants are zero-argument methods).
      const base = /_instance\.\w+$/.test(callee) ? `${callee}()` : callee;
      return n.args.length ? this.applyRest(base, n.args, n) : base;
    }
    const given = n.args.slice(0, arity), rest = n.args.slice(arity);
    // Holes (omitted labelled or missing trailing arguments) become closure parameters.
    const holes = [];
    for (let i = 0; i < arity; i++) if (!(i < given.length && given[i].e)) holes.push(i);
    const names = holes.map(() => this.temp('a'));
    const nodes = [];
    for (let i = 0; i < arity; i++) {
      const h = holes.indexOf(i);
      let e = h >= 0 ? {k: '$var', name: names[h], t: formal[i].t} : given[i].e;
      const label = scheme[i].label;
      if (label.startsWith('?')) {
        if (h < 0 && e.k === 'construct' && e.c.type?.p === 'option') e = e.c.name === 'None' ? {k: '$omit'} : e.args[0];
        else e = {k: '$expr', code: `(switch (${this.value(e)}) { case ${RT}MlOption.Some(_o): _o; case ${RT}MlOption.None: null; })`, impure: true};
      }
      const k = this.schemeArity(scheme[i].t);
      if (k >= 2 && e.k !== '$omit') e = this.uncurriedArg(e, k, formal[i].t, n);
      nodes.push({label, e});
    }
    const order = [...nodes.filter(x => !x.label.startsWith('?')), ...nodes.filter(x => x.label.startsWith('?'))];
    while (order.length && order.at(-1).e.k === '$omit') order.pop();
    const evals = order.map(x => x.e.k === '$omit' ? {k: '$expr', code: 'null'} : x.e);
    let call = this.ordered(evals, vals => `${callee}(${vals.join(', ')})`);
    if (holes.length) {
      if (rest.length) this.fail(n, 'over-application after omitted arguments');
      let ty = this.chainType(formal.slice(arity), res, n);
      for (let k = holes.length - 1; k >= 0; k--) {
        const at = this.type(formal[holes[k]].t, n);
        call = `function(${names[k]}:${at}):${ty} return ${call}`;
        ty = `(${at}) -> (${ty})`;
      }
      return `(${call})`;
    }
    return rest.length ? this.applyRest(call, rest, n) : call;
  }
  // A function argument for a library parameter of k arrows: uncurried.
  uncurriedArg(e, k, t, n) {
    const {args, res} = this.arrows(t);
    if (args.length < k) this.fail(n, 'function argument with fewer arrows than the signature');
    const resT = k < args.length ? this.chainType(args.slice(k), res, n) : this.type(res, n);
    if (e.k === 'fun') {
      const fn = funInfo(e);
      if (fn.arity === k) { const f = this.functionParts(fn, e, null); return {k: '$expr', code: `function(${f.params}):${f.res} ${f.body}`}; }
    }
    if (e.k === 'ident') {
      const d = this.identDesc(e);
      const direct = d.kind === 'static' || d.kind === 'external' ? d.hx : d.kind === 'localfn' ? d.name : null;
      if (direct && d.arity === k) return {k: '$expr', code: direct};
    }
    const f = this.temp('f'), ps = args.slice(0, k).map(() => this.temp('a'));
    const call = ps.reduce((acc, p) => `${acc}(${p})`, f);
    return {k: '$expr', impure: true, code: `{ var ${f} = ${this.value(e)}; function(${ps.map((p, i) => `${p}:${this.type(args[i].t, n)}`).join(', ')}):${resT} return ${call}; }`};
  }
  knownCall(callee, arity, n, fn, nullary = false) {
    if (nullary) return n.args.length ? this.applyRest(`${callee}()`, n.args, n) : `${callee}()`;
    const args = n.args;
    const {args: formal, res} = this.arrows(fn.t);
    // Arguments up to the arity: holes (omitted labelled args) and missing
    // trailing ones become closure parameters.
    const first = args.slice(0, arity), rest = args.slice(arity);
    const supplied = first.filter(a => a.e).map(a => a.e);
    if (first.length === arity && first.every(a => a.e)) {
      const call = this.ordered(first.map(a => a.e), vals => `${callee}(${vals.join(', ')})`);
      if (!rest.length) return call;
      return this.applyRest(call, rest, n);
    }
    // Partial application: evaluate supplied args now (right to left).
    const temps = [], decls = [];
    for (let i = first.length - 1; i >= 0; i--) {
      if (!first[i].e) continue;
      const t = this.temp();
      temps[i] = t; decls.push(`var ${t} = ${this.value(first[i].e)};`);
    }
    const holes = [];
    for (let i = 0; i < arity; i++) if (!(i < first.length && first[i].e)) holes.push(i);
    const names = holes.map(() => this.temp('a'));
    const callArgs = [];
    for (let i = 0; i < arity; i++) { const h = holes.indexOf(i); callArgs.push(h >= 0 ? names[h] : temps[i]); }
    let body = `${callee}(${callArgs.join(', ')})`;
    let ty = this.chainType(formal.slice(arity), res, n);
    for (let k = holes.length - 1; k >= 0; k--) {
      const at = this.type(formal[holes[k]].t, n);
      body = `function(${names[k]}:${at}):${ty} return ${body}`;
      ty = `(${at}) -> (${ty})`;
    }
    if (rest.length) this.fail(n, 'over-application after omitted arguments');
    return `{ ${decls.join(' ')} ${body}; }`;
  }
  applyRest(call, rest, n) {
    if (rest.some(a => !a.e)) this.fail(n, 'omitted argument in over-application');
    return this.ordered(rest.map(a => a.e), vals => vals.reduce((acc, a) => `${acc}(${a})`, `(${call})`));
  }
  partialUnknown(n) {
    // f ~x:1 with f unknown and other labelled args omitted.
    const {args: formal, res} = this.arrows(n.fn.t);
    const temps = [], decls = [];
    n.args.forEach((a, i) => { if (a.e) { const t = this.temp(); temps[i] = t; } });
    for (let i = n.args.length - 1; i >= 0; i--) if (n.args[i].e) decls.push(`var ${temps[i]} = ${this.value(n.args[i].e)};`);
    const f = this.temp('f');
    decls.push(`var ${f} = ${this.value(n.fn)};`);
    const holes = n.args.map((a, i) => a.e ? null : i).filter(x => x !== null);
    const names = holes.map(() => this.temp('a'));
    let body = n.args.reduce((acc, a, i) => `${acc}(${a.e ? temps[i] : names[holes.indexOf(i)]})`, f);
    let ty = this.chainType(formal.slice(n.args.length), res, n);
    for (let k = holes.length - 1; k >= 0; k--) {
      const at = this.type(formal[holes[k]].t, n);
      body = `function(${names[k]}:${at}):${ty} return ${body}`;
      ty = `(${at}) -> (${ty})`;
    }
    return `{ ${decls.join(' ')} ${body}; }`;
  }

  // ------------------------------------------------------------ primitives
  primValue(d, n, where) {
    if (!n) this.fail(where, `primitive ${d.prim} as a value`);
    const {args} = this.arrows(n.t);
    const arity = d.arity;
    // Eta-expand into a curried closure around the inline operation.
    if (args.length < arity) this.fail(where, `primitive ${d.prim} as a value with ${args.length} of its ${arity} arguments`);
    const names = args.slice(0, arity).map(() => this.temp('a'));
    const fake = {k: 'apply', $eta: true, t: null, l: n.l, fn: n, args: names.map((x, i) => ({label: '', e: {k: '$var', name: x, t: args[i].t}}))};
    const {res} = this.arrows(n.t);
    fake.t = this.resultAfter(n.t, arity);
    let body = this.primApply(d.prim, fake, n);
    if (body === null) this.fail(where, `primitive ${d.prim}`);
    let ty = this.type(fake.t, where);
    for (let i = arity - 1; i >= 0; i--) {
      const at = this.type(args[i].t, where);
      body = `function(${names[i]}:${at}):${ty} return ${body}`;
      ty = `(${at}) -> (${ty})`;
    }
    return `(${body})`;
  }
  resultAfter(t, k) { for (let i = 0; i < k; i++) t = this.t(t).res; return t; }
  primApply(prim, n, fn) {
    const args = n.args;
    const arity = {'%identity': 1, '%ignore': 1, '%obj_magic': 1}[prim];
    const P = this.primitives();
    const spec = P[prim];
    if (!spec) return null;
    if (args.length < spec.arity || args.slice(0, spec.arity).some(a => !a.e)) {
      if (n.$eta) this.fail(n, `primitive ${prim} with fewer arguments than its arity`);
      // Partial: eta through primValue.
      const f = this.primValue({prim, arity: spec.arity}, fn, n);
      return this.ordered(args.map(a => a.e ?? this.fail(n, 'omitted primitive argument')), vals => vals.reduce((acc, a) => `${acc}(${a})`, f));
    }
    const first = args.slice(0, spec.arity).map(a => a.e), rest = args.slice(spec.arity);
    let r;
    if (spec.lazy) r = spec.lazy(first, n);
    else r = this.ordered(first, vals => spec.code(vals, first, n));
    return rest.length ? this.applyRest(r, rest, n) : r;
  }
  primitives() {
    if (this._prims) return this._prims;
    const I63 = `${RT}Int63`;
    const int = fn => ({arity: 2, code: v => `${I63}.${fn}(${v[0]}, ${v[1]})`});
    const cmp = (op, fn) => ({arity: 2, code: (v, a, n) => this.compare(op, v, a, n)});
    const toInt = x => `${wrap(x)}.toInt()`;
    const ofInt = x => `${I63}.ofInt(${x})`;
    const P = {
      '%addint': int('add'), '%subint': int('sub'), '%mulint': int('mul'), '%divint': int('div'), '%modint': int('mod'),
      '%negint': {arity: 1, code: v => `${I63}.neg(${v[0]})`},
      '%succint': {arity: 1, code: v => `${I63}.succ(${v[0]})`}, '%predint': {arity: 1, code: v => `${I63}.pred(${v[0]})`},
      '%andint': int('logand'), '%orint': int('logor'), '%xorint': int('logxor'),
      '%lslint': int('shiftLeft'), '%lsrint': int('shiftRightLogical'), '%asrint': int('shiftRight'),
      '%eq': cmp('=='), '%noteq': cmp('!='), '%equal': cmp('='), '%notequal': cmp('<>'),
      '%lessthan': cmp('<'), '%greaterthan': cmp('>'), '%lessequal': cmp('<='), '%greaterequal': cmp('>='), '%compare': cmp('compare'),
      '%boolnot': {arity: 1, code: v => `!${wrap(v[0])}`},
      '%sequand': {arity: 2, lazy: a => `(${wrap(this.value(a[0]))} && ${wrap(this.value(a[1]))})`},
      '%sequor': {arity: 2, lazy: a => `(${wrap(this.value(a[0]))} || ${wrap(this.value(a[1]))})`},
      '%identity': {arity: 1, code: (v, a, n) => this.identity(v[0], a[0], n)},
      '%obj_magic': {arity: 1, code: (v, a, n) => this.identity(v[0], a[0], n)},
      '%opaque': {arity: 1, code: v => v[0]},
      '%ignore': {arity: 1, code: v => `{ ${v[0]}; ${UNIT}; }`},
      '%makemutable': {arity: 1, code: v => `new ${RT}Ref(${v[0]})`},
      '%field0': {arity: 1, code: (v, a) => `${wrap(v[0])}.${this.isTupleType(a[0].t) ? 'v0' : 'value'}`},
      '%field1': {arity: 1, code: v => `${wrap(v[0])}.v1`},
      '%loc_LOC': {arity: 0, code: (v, a, n) => haxeString(`File "${this.cfg.source}", line ${n.l[0]}, characters ${n.l[1]}-${n.l[1]}`)},
      '%loc_MODULE': {arity: 0, code: () => haxeString(this.u.modname)},
      '%loc_POS': {arity: 0, code: (v, a, n) => `new ${RT}Tuple4(${haxeString(this.cfg.source)}, ${this.intLit(n.l[0])}, ${this.intLit(n.l[1])}, ${this.intLit(n.l[1])})`},
      '%setfield0': {arity: 2, code: v => `{ ${wrap(v[0])}.value = ${v[1]}; ${UNIT}; }`},
      '%incr': {arity: 1, code: v => `{ var _r = ${v[0]}; _r.value = ${I63}.succ(_r.value); ${UNIT}; }`},
      '%decr': {arity: 1, code: v => `{ var _r = ${v[0]}; _r.value = ${I63}.pred(_r.value); ${UNIT}; }`},
      '%raise': {arity: 1, code: v => `throw ${v[0]}`}, '%reraise': {arity: 1, code: v => `throw ${v[0]}`}, '%raise_notrace': {arity: 1, code: v => `throw ${v[0]}`},
      '%revapply': {arity: 2, lazy: (a, n) => this.apply({k: 'apply', t: n.t, l: n.l, fn: a[1], args: [{label: '', e: a[0]}]})},
      '%apply': {arity: 2, lazy: (a, n) => this.apply({k: 'apply', t: n.t, l: n.l, fn: a[0], args: [{label: '', e: a[1]}]})},
      '%string_length': {arity: 1, code: v => ofInt(`${wrap(v[0])}.length`)}, '%bytes_length': {arity: 1, code: v => ofInt(`${wrap(v[0])}.length`)},
      '%string_safe_get': {arity: 2, code: v => `${RT}Runtime.stringGet(${v[0]}, ${toInt(v[1])})`},
      '%string_unsafe_get': {arity: 2, code: v => `StringTools.fastCodeAt(${v[0]}, ${toInt(v[1])})`},
      '%bytes_safe_get': {arity: 2, code: v => `${RT}Runtime.bytesGet(${v[0]}, ${toInt(v[1])})`}, '%bytes_unsafe_get': {arity: 2, code: v => `${wrap(v[0])}.get(${toInt(v[1])})`},
      '%bytes_safe_set': {arity: 3, code: v => `${RT}Runtime.bytesSet(${v[0]}, ${toInt(v[1])}, ${v[2]})`}, '%bytes_unsafe_set': {arity: 3, code: v => `{ ${wrap(v[0])}.set(${toInt(v[1])}, ${v[2]}); ${UNIT}; }`},
      '%array_length': {arity: 1, code: v => ofInt(`${wrap(v[0])}.length`)}, '%floatarray_length': {arity: 1, code: v => ofInt(`${wrap(v[0])}.length`)},
      '%array_safe_get': {arity: 2, code: v => `${RT}Runtime.arrayGet(${v[0]}, ${toInt(v[1])})`}, '%array_unsafe_get': {arity: 2, code: v => `${wrap(v[0])}[${toInt(v[1])}]`},
      '%array_safe_set': {arity: 3, code: v => `${RT}Runtime.arraySet(${v[0]}, ${toInt(v[1])}, ${v[2]})`}, '%array_unsafe_set': {arity: 3, code: v => `{ ${wrap(v[0])}[${toInt(v[1])}] = ${v[2]}; ${UNIT}; }`},
      '%floatofint': {arity: 1, code: v => `${I63}.toFloat(${v[0]})`}, '%intoffloat': {arity: 1, code: v => `${I63}.ofFloat(${v[0]})`},
      '%addfloat': {arity: 2, code: v => `(${wrap(v[0])} + ${wrap(v[1])})`}, '%subfloat': {arity: 2, code: v => `(${wrap(v[0])} - ${wrap(v[1])})`},
      '%mulfloat': {arity: 2, code: v => `(${wrap(v[0])} * ${wrap(v[1])})`}, '%divfloat': {arity: 2, code: v => `(${wrap(v[0])} / ${wrap(v[1])})`},
      '%negfloat': {arity: 1, code: v => `(-${v[0]})`}, '%absfloat': {arity: 1, code: v => `Math.abs(${v[0]})`},
      '%loc_FILE': {arity: 0, code: () => haxeString(this.cfg.source)}, '%loc_LINE': {arity: 0, code: (v, a, n) => this.intLit(n.l[0])},
      '%int_as_pointer': null,
    };
    for (const [k, v] of Object.entries(P)) if (!v) delete P[k];
    return this._prims = P;
  }
  identity(v, arg, n) {
    // %identity: Obj.magic, Obj.repr/obj, int_of_char, unsafe_chr.
    let from, to;
    try { from = this.type(arg.t, n); to = this.type(n.t, n); } catch (e) { from = to = null; }
    if (from !== null && from === to) return v;
    if (this.isPredef(arg.t, 'char') && this.isInt(n.t)) return `${RT}Int63.ofInt(${v})`;
    if (this.isInt(arg.t) && this.isPredef(n.t, 'char')) return `(${wrap(v)}.toInt() & 255)`;
    const target = this.typeOrNull(n.t, n);
    return target ? `(cast ${v} : ${target})` : `(cast ${v})`;
  }
  // Comparison of two values with OCaml's semantics.
  compare(op, v, a, n) {
    const t = this.t(a[0].t);
    if (op === '==' || op === '!=') {
      if (this.isInt(a[0].t)) return `${op === '!=' ? '!' : ''}${RT}Int63.eq(${v[0]}, ${v[1]})`;
      return `(${wrap(v[0])} ${op} ${wrap(v[1])})`;
    }
    if (this.isInt(a[0].t)) {
      const fn = {'=': 'eq', '<>': 'eq', '<': 'lt', '>': 'gt', '<=': 'le', '>=': 'ge', compare: 'compare'}[op];
      const call = `${RT}Int63.${fn}(${v[0]}, ${v[1]})`;
      return op === '<>' ? `!${call}` : op === 'compare' ? `${RT}Int63.ofInt(${call})` : call;
    }
    const simple = t.k === 'constr' && ['char', 'bool', 'string', 'float'].includes(t.path.p);
    if (simple && op !== 'compare') {
      const o = {'=': '==', '<>': '!='}[op] ?? op;
      if (t.path.p === 'bool' && !['==', '!='].includes(o)) return `${RT}Runtime.compareBool(${v[0]}, ${v[1]}) ${o} 0`;
      return `(${wrap(v[0])} ${o} ${wrap(v[1])})`;
    }
    if (op === 'compare') {
      if (simple && t.path.p !== 'float' && t.path.p !== 'bool') return `${RT}Int63.ofInt(${RT}Runtime.compare${t.path.p === 'string' ? 'String' : 'Int'}(${v[0]}, ${v[1]}))`;
      return `${RT}Int63.ofInt(${RT}Runtime.compare(${v[0]}, ${v[1]}))`;
    }
    if (op === '=') return `${RT}Runtime.equal(${v[0]}, ${v[1]})`;
    if (op === '<>') return `!${RT}Runtime.equal(${v[0]}, ${v[1]})`;
    return `(${RT}Runtime.compare(${v[0]}, ${v[1]}) ${op} 0)`;
  }
  // Library calls the emitter compiles itself (format strings).
  libApply(d, n, fn) {
    const key = `${libraryModule(d.path[0])}${d.path.length > 1 ? '.' + d.path.slice(1).join('.') : ''}.${d.name}`;
    const fmt = {'Printf.sprintf': 'sprintf', 'Printf.printf': 'printf', 'Printf.eprintf': 'eprintf', 'Printf.fprintf': 'fprintf', 'Printf.bprintf': 'bprintf', 'Printf.ksprintf': 'ksprintf', 'Printf.kprintf': 'ksprintf', 'Stdlib.failwith': null, 'Stdlib.invalid_arg': null, 'Stdlib.^': 'concat'}[key];
    if (key === 'Stdlib.^' && n.args.length === 2 && n.args.every(a => a.e)) return this.ordered(n.args.map(a => a.e), v => `(${wrap(v[0])} + ${wrap(v[1])})`);
    if (key === 'Stdlib.failwith' && n.args.length === 1 && n.args[0].e) return `throw new ${RT}Failure(${this.value(n.args[0].e)})`;
    if (key === 'Stdlib.invalid_arg' && n.args.length === 1 && n.args[0].e) return `throw new ${RT}InvalidArgument(${this.value(n.args[0].e)})`;
    if (fmt && fmt !== 'concat') return this.printf(fmt, n, fn);
    return null;
  }

  // ------------------------------------------------------------ format strings
  // Printf.sprintf "lit%d..." a b: the format is a CamlinternalFormatBasics
  // constructor tree in the typed tree; compile it to concatenation.
  printf(kind, n, fn) {
    const lead = kind === 'fprintf' || kind === 'bprintf' || kind === 'ksprintf' ? 1 : 0;
    if (n.args.length <= lead || !n.args[lead].e) return null;
    const fmtNode = n.args[lead].e;
    const pieces = this.formatPieces(fmtNode);
    if (!pieces) return this.printfValue(kind, lead, n, fn);
    const holes = pieces.filter(p => p.conv);
    const supplied = n.args.slice(lead + 1);
    if (supplied.some(a => !a.e)) this.fail(n, 'omitted format argument');
    const {args: formal} = this.arrows(this.resultAfter(fn.t, lead + 1));
    const names = holes.map(() => this.temp('p'));
    const leadVals = n.args.slice(0, lead).map(a => this.value(a.e));
    const concat = () => {
      let i = 0;
      const parts = pieces.map(p => p.lit !== undefined ? haxeString(p.lit) : wrap(this.formatConv(p, names[i++], formal[i - 1]?.t, n)));
      return parts.length ? parts.join(' + ') : '""';
    };
    let body;
    const str = `(${concat()})`;
    switch (kind) {
      case 'sprintf': body = str; break;
      case 'printf': body = `{ ${STD}Stdlib.printString(${str}); ${UNIT}; }`; this.p.useLibrary(`${STD}Stdlib`, 'printString', '(s:String):ml2hx.rt.Unit'); break;
      case 'eprintf': body = `{ ${STD}Stdlib.prerrString(${str}); ${UNIT}; }`; this.p.useLibrary(`${STD}Stdlib`, 'prerrString', '(s:String):ml2hx.rt.Unit'); break;
      case 'fprintf': body = `{ ${STD}Stdlib.outputString(${leadVals[0]}, ${str}); ${UNIT}; }`; this.p.useLibrary(`${STD}Stdlib`, 'outputString', '(c:OutChannel, s:String):ml2hx.rt.Unit'); break;
      case 'bprintf': body = `{ ${STD}Buffer.addString(${leadVals[0]}, ${str}); ${UNIT}; }`; this.p.useLibrary(`${STD}Buffer`, 'addString', '(b:T, s:String):ml2hx.rt.Unit'); break;
      case 'ksprintf': body = `${leadVals[0]}(${str})`; break;
    }
    // Saturated: bind the arguments (right to left) and build the string.
    const k = Math.min(holes.length, supplied.length);
    const decls = [];
    for (let i = k - 1; i >= 0; i--) decls.push(`var ${names[i]} = ${this.value(supplied[i].e)};`);
    let result = body;
    let ty = this.type(this.resultAfter(fn.t, lead + 1 + holes.length), n);
    for (let i = holes.length - 1; i >= k; i--) {
      const at = this.type(formal[i].t, n);
      result = `function(${names[i]}:${at}):${ty} return ${result}`;
      ty = `(${at}) -> (${ty})`;
    }
    let out = `{ ${decls.join(' ')} ${result}; }`;
    if (supplied.length > holes.length) out = this.applyRest(out, supplied.slice(holes.length), n);
    return out;
  }
  // A format that is a value (a parameter, a stored format): the runtime's
  // Printf over ml2hx.rt.Fmt. With the arity known from the format's type the
  // arguments go as an array; in generic code the runtime builds the curried
  // function from the format.
  printfValue(kind, lead, n, fn) {
    const fmtNode = n.args[lead].e;
    const ft = this.t(fmtNode.t);
    const arity = ft.k === 'constr' && ft.args.length ? this.schemeArity(ft.args[0]) : 0;
    const generic = ft.k === 'constr' && ft.args.length && this.t(ft.args[0]).k === 'var';
    const supplied = n.args.slice(lead + 1);
    if (supplied.some(a => !a.e)) this.fail(n, 'omitted format argument');
    const leadVals = n.args.slice(0, lead + 1).map(a => this.value(a.e));
    const call = {sprintf: 'sprintf', printf: 'printf', eprintf: 'eprintf', fprintf: 'fprintf', bprintf: 'bprintf', ksprintf: 'ksprintf'}[kind];
    if (generic) {
      const k = kind === 'ksprintf' ? leadVals[0] : null;
      const res = this.type(this.resultAfter(fn.t, lead + 1), n);
      const base = `(cast ${STD}Printf.curried(${leadVals[lead]}, ${this.printfFinisher(kind, leadVals)}) : ${res})`;
      return supplied.length ? this.applyRest(base, supplied, n) : base;
    }
    const first = supplied.slice(0, arity), rest = supplied.slice(arity);
    const {args: formal, res} = this.arrows(this.resultAfter(fn.t, lead + 1));
    const names = [], vals = first.map(a => this.value(a.e));
    for (let i = first.length; i < arity; i++) names.push(this.temp('p'));
    let body = `${STD}Printf.${call}(${leadVals.join(', ')}, ([${[...vals, ...names].join(', ')}] : Array<Any>))`;
    let ty = this.type(this.resultAfter(fn.t, lead + 1 + arity), n);
    for (let i = arity - 1; i >= first.length; i--) {
      const at = this.type(formal[i].t, n);
      body = `function(${names[i - first.length]}:${at}):${ty} return ${body}`;
      ty = `(${at}) -> (${ty})`;
    }
    return rest.length ? this.applyRest(body, rest, n) : body;
  }
  printfFinisher(kind, leads) {
    switch (kind) {
      case 'sprintf': return `function(s:String) return s`;
      case 'ksprintf': return leads[0];
      case 'printf': return `function(s:String) return ${STD}Stdlib.printString(s)`;
      case 'eprintf': return `function(s:String) return ${STD}Stdlib.prerrString(s)`;
      case 'fprintf': return `function(s:String) return ${STD}Stdlib.outputString(${leads[0]}, s)`;
      case 'bprintf': return `function(s:String) return ${STD}Buffer.addString(${leads[0]}, s)`;
    }
  }
  formatPieces(node) {
    // Format (fmt, str) -> list of {lit} | {conv, ...}
    if (node.k !== 'construct' || node.c.name !== 'Format') return null;
    const out = [];
    let f = node.args[0];
    while (true) {
      if (f.k !== 'construct') return null;
      const c = f.c.name, a = f.args;
      if (c === 'End_of_format') break;
      if (c === 'String_literal') { out.push({lit: a[0].c.v}); f = a[1]; continue; }
      if (c === 'Char_literal') { out.push({lit: String.fromCharCode(a[0].c.v)}); f = a[1]; continue; }
      if (c === 'String' || c === 'Caml_string') { out.push({conv: c === 'String' ? 's' : 'S', pad: a[0]}); f = a[1]; continue; }
      if (c === 'Char' || c === 'Caml_char') { out.push({conv: c === 'Char' ? 'c' : 'C'}); f = a[0]; continue; }
      if (c === 'Int' || c === 'Int32' || c === 'Int64' || c === 'Nativeint') { out.push({conv: c, iconv: a[0].c.name, pad: a[1], prec: a[2]}); f = a[3]; continue; }
      if (c === 'Float') { out.push({conv: 'f', fconv: a[0], pad: a[1], prec: a[2]}); f = a[3]; continue; }
      if (c === 'Bool') { out.push({conv: 'B', pad: a[0]}); f = a[1]; continue; }
      if (c === 'Flush') { f = a[0]; continue; }
      if (c === 'Alpha' || c === 'Theta') return null;
      return null;
    }
    // Merge adjacent literals.
    const merged = [];
    for (const p of out) { if (p.lit !== undefined && merged.length && merged.at(-1).lit !== undefined) merged.at(-1).lit += p.lit; else merged.push(p); }
    return merged;
  }
  formatConv(p, v, t, n) {
    const noPad = x => !x || (x.k === 'construct' && x.c.name === 'No_padding');
    const noPrec = x => !x || (x.k === 'construct' && x.c.name === 'No_precision');
    const simple = noPad(p.pad) && noPrec(p.prec);
    if (p.conv === 's' && noPad(p.pad)) return v;
    if (p.conv === 'c') return `String.fromCharCode(${v})`;
    if (p.conv === 'B') return `(${v} ? "true" : "false")`;
    if (p.conv === 'Int' && simple && ['Int_d', 'Int_i'].includes(p.iconv)) return `${wrap(v)}.toString()`;
    // Everything else: the runtime's conversion of one specification.
    return `${RT}Fmt.one(${JSON.stringify(this.convSpec(p, n))}, ${v})`;
  }
  convSpec(p, n) {
    // Rebuild the %-specification text from the constructor tree.
    const pad = p.pad, prec = p.prec;
    let flags = '', width = '', precision = '';
    if (pad && pad.k === 'construct' && pad.c.name === 'Lit_padding') {
      const side = pad.args[0].c.name;
      flags += side === 'Left' ? '-' : side === 'Zeros' ? '0' : '';
      width = pad.args[1].c.v;
    } else if (pad && pad.k === 'construct' && pad.c.name !== 'No_padding') this.fail(n, 'computed format padding');
    if (prec && prec.k === 'construct' && prec.c.name === 'Lit_precision') precision = '.' + prec.args[0].c.v;
    else if (prec && prec.k === 'construct' && prec.c.name !== 'No_precision') this.fail(n, 'computed format precision');
    let conv = '';
    if (p.conv === 'Int' || p.conv === 'Int32' || p.conv === 'Int64' || p.conv === 'Nativeint') {
      const m = {Int_d: 'd', Int_pd: '+d', Int_sd: ' d', Int_i: 'i', Int_pi: '+i', Int_si: ' i', Int_x: 'x', Int_Cx: '#x', Int_X: 'X', Int_CX: '#X', Int_o: 'o', Int_Co: '#o', Int_u: 'u', Int_Cd: 'd', Int_Ci: 'i', Int_Cu: 'u'}[p.iconv];
      if (!m) this.fail(n, 'int conversion ' + p.iconv);
      flags += m.length > 1 ? m[0] : ''; conv = {Int: '', Int32: 'l', Int64: 'L', Nativeint: 'n'}[p.conv] + m.at(-1);
    } else if (p.conv === 'f') {
      const fc = p.fconv; // (float_flag_conv, float_kind_conv)
      const flag = fc.args[0].c.name, kind = fc.args[1].c.name;
      flags += flag === 'Float_flag_p' ? '+' : flag === 'Float_flag_s' ? ' ' : '';
      conv = {Float_f: 'f', Float_e: 'e', Float_E: 'E', Float_g: 'g', Float_G: 'G', Float_F: 'F', Float_h: 'h', Float_H: 'H', Float_CF: '#F'}[kind] ?? this.fail(n, 'float conversion ' + kind);
    } else conv = p.conv;
    return `%${flags}${width}${precision}${conv}`;
  }

  // ------------------------------------------------------------ data
  construct(n) {
    const c = n.c;
    if (c.name === 'Format' && pathName(c.type ?? {}).endsWith('format6') && n.args[1]?.k === 'const') return `${RT}Fmt.of(${haxeString(n.args[1].c.v)})`;
    if (c.ext) return this.extConstruct(n);
    const special = {'true': 'true', 'false': 'false', '()': UNIT, '[]': `${RT}MlList.Nil`, 'None': `${RT}MlOption.None`};
    if (c.name === '[]' || c.name === '()' || c.name === 'true' || c.name === 'false') return special[c.name];
    if (c.type?.p && special[c.name] !== undefined && c.type.p === 'option') return special[c.name];
    if (c.name === '::') return this.ordered(n.args, a => `${RT}MlList.Cons(${a.join(', ')})`);
    if (c.name === 'Some' && c.type?.p === 'option') return this.ordered(n.args, a => `${RT}MlOption.Some(${a[0]})`);
    const name = this.ctorRef(c, n);
    if (c.inline) {
      const r = n.args[0];
      const cls = `${name.replace(/\.[^.]+$/, '')}_${c.name}`;
      return `${name}(${this.record(r, cls)})`;
    }
    return n.args.length ? this.ordered(n.args, a => `${name}(${a.join(', ')})`) : name;
  }
  ctorRef(c, n) {
    const d = this.resolveType(c.type, n);
    if (d.decl?.kind === 'variant' || d.library) return `${d.hx}.${c.name}`;
    if (d.hx && !d.decl) return `${d.hx}.${c.name}`;
    this.fail(n, `constructor ${c.name} of ${pathName(c.type)}`);
  }
  exnClass(p, n) {
    if (p.p) { const e = predefExns[p.p]; if (!e) this.fail(n, `predefined exception ${p.p}`); return `${RT}${e}`; }
    if (p.l) { const d = this.ids.get(p.l); if (!d) this.fail(n, `unknown exception ${pathName(p)}`); return d.kind === 'exnalias' ? this.exnClass(d.path, n) : d.hx; }
    if (p.d) {
      const m = this.resolveModule(p.d[0], n);
      if (m.kind === 'lib') { const hx = m.exnHx(p.d[1]); this.p.useLibrary(m.hx, `exception ${hx}`, ''); return hx; }
      if (m.kind === 'struct') { const d = m.exns.get(p.d[1]); if (!d) this.fail(n, `unknown exception ${pathName(p)}`); return d.kind === 'exnalias' ? this.exnClass(d.path, n) : d.hx; }
    }
    this.fail(n, `exception path ${pathName(p)}`);
  }
  extConstruct(n) {
    const cls = this.exnClass(n.c.ext, n);
    // Constant exceptions are one value each, as in OCaml.
    if (!n.args.length && n.c.type?.p === 'exn') return `${cls}.instance`;
    return this.ordered(n.args, a => `new ${cls}(${a.join(', ')})`);
  }
  record(n, cls = null) {
    // Without inferable type arguments, Haxe infers them from the fields.
    const t = cls ?? this.typeOrNull(n.t, n) ?? this.type(n.t, n).replace(/<.*$/, '');
    const fields = n.fields;
    const base = n.base ? this.temp('r') : null;
    const given = fields.filter(f => f.e).map(f => f.e);
    // { e with ... }: the base is evaluated first, then the fields right to left.
    const build = (b) => this.ordered(given, vals => {
      let i = 0;
      const args = fields.map(f => f.e ? vals[i++] : `${b}.${this.fieldName(f.lbl)}`);
      return `new ${t}(${args.join(', ')})`;
    });
    if (!n.base) return build(null);
    return `{ var ${base} = ${this.value(n.base)}; ${build(base)}; }`;
  }

  // ------------------------------------------------------------ loops
  forLoop(n) {
    const i = this.fresh(identName(n.id)), lim = this.temp('n');
    this.ids.set(n.id, {kind: 'local', name: i});
    const from = this.value(n.from), to = this.value(n.to);
    // OCaml evaluates the start, then the end, once.
    const v = this.temp('i');
    const I = `${RT}Int63`;
    return `{ var ${v} = ${from}; var ${lim} = ${to}; while (${I}.${n.up ? 'le' : 'ge'}(${v}, ${lim})) { var ${i} = ${v}; ${this.stmt(n.body)} if (${I}.eq(${v}, ${lim})) break; ${v} = ${I}.${n.up ? 'succ' : 'pred'}(${v}); } }`;
  }

  // ------------------------------------------------------------ matching
  matchFailure(n) { return `new ${RT}MatchFailure(${haxeString(this.cfg.source)}, ${this.intLit(n.l?.[0] ?? 0)}, ${this.intLit(n.l?.[1] ?? 0)})`; }
  matchNode(n, tc, mode) {
    const value = n.cases.filter(c => !hasException(c.p)), exns = n.cases.filter(c => hasException(c.p));
    if (exns.length) return this.matchWithExceptions(n, value, exns, tc, mode);
    // match (a, b) with ... on a syntactic tuple: no allocation.
    const scrut = n.e;
    if (scrut.k === 'tuple' && value.every(c => tupleLike(c.p, scrut.args.length))) {
      // Haxe matches `switch [a, b]` without an array only on a literal
      // array subject: effects go to temporaries first (right to left).
      const decls = [];
      const vals = scrut.args.map(a => pure(a) ? this.value(a) : null);
      for (let i = scrut.args.length - 1; i >= 0; i--) if (vals[i] === null) { const t = this.temp(); decls.unshift(`var ${t} = ${this.value(scrut.args[i])};`); vals[i] = t; }
      const cases = value.map(c => ({...c, p: c.p, tupleScrutinee: true}));
      const code = this.switchCode(`[${vals.join(', ')}]`, cases, n.partial, tc, mode, n, scrut.args.length);
      if (!decls.length) return code;
      const ordered = decls.reverse().join(' ');
      return mode === 'value' ? `{ ${ordered} ${code}; }` : `{ ${ordered} ${code} }`;
    }
    if (this.isInt(scrut.t) && value.every(c => intKeyPattern(c.p))) return this.intSwitch(this.value(scrut), value, n.partial, tc, mode, n);
    return this.switchCode(this.value(scrut), value, n.partial, tc, mode, n);
  }
  matchStmt(scrut, scrutType, cases, partial, tc, n, inlineBodies = false) {
    if (this.isInt(scrutType) && cases.every(c => intKeyPattern(c.p))) return this.intSwitch(scrut, cases, partial, tc, 'ret', n);
    return this.switchCode(scrut, cases, partial, tc, 'ret', n);
  }
  // A match on an int over constants: a switch on the Int key of the
  // value (Haxe matches literal patterns on Int, not on Int63).
  intSwitch(subject, cases, partial, tc, mode, n) {
    const s = this.temp('s');
    const keyed = cases.map(c => ({...c, p: intKeyed(c.p, s)}));
    const code = this.switchCode(`${RT}Int63.patternKey(${s})`, keyed, partial, tc, mode, n);
    return mode === 'value' ? `{ var ${s} = ${subject}; ${code}; }` : `{ var ${s} = ${subject}; ${code} }`;
  }
  // Emits a Haxe switch. mode: 'value' (expression), 'stmt', 'ret' (return/continue).
  switchCode(subject, cases, partial, tc, mode, n, tupleArity = 0) {
    const arms = [];
    let opaque = false;
    // Or-patterns over extensible constructors (extractors) become one arm
    // per alternative: Haxe or-patterns need alternatives of one kind.
    const alts = p => p.k === 'or' && hasExtractor(p) ? [...alts(p.a), ...alts(p.b)] : p.k === 'value' && p.p.k === 'or' && hasExtractor(p.p) ? alts(p.p) : [p];
    cases = cases.flatMap(c => alts(c.p).map(p => ({...c, p})));
    for (const c of cases) {
      const saved = new Map(this.ids);
      const pat = tupleArity ? this.tuplePattern(c.p, tupleArity) : this.pattern(c.p);
      const guard = [pat.guard, c.guard ? this.value(c.guard) : null].filter(Boolean).join(' && ');
      if (pat.guard || pat.pat.includes('=>')) opaque = true;
      const pre = pat.pre ?? '';
      let body;
      if (mode === 'value') body = `${pre ? `{ ${pre} ${this.value(c.e)}; }` : this.value(c.e)}`;
      else if (mode === 'stmt') body = `${pre} ${this.stmt(c.e)}`;
      else body = `${pre} ${this.ret(c.e, tc)}`;
      arms.push(`case ${pat.pat}${guard ? ` if (${guard})` : ''}: ${mode === 'value' ? body + ';' : body}`);
      this.ids = saved;
    }
    if (partial || !cases.length || opaque) arms.push(`case _: throw ${this.matchFailure(n)};`);
    const code = `switch (${subject}) { ${arms.join(' ')} }`;
    return mode === 'value' ? `(${code})` : code;
  }
  matchWithExceptions(n, value, exns, tc, mode) {
    const opt = this.temp('m'), exn = this.temp('e'), v = this.temp('v');
    const scrutT = this.type(n.e.t, n);
    const tryPart = `var ${exn}:${RT}MlException = null; var ${opt} = try ${RT}MlOption.Some(${this.value(n.e)}) catch (_x:haxe.Exception) { ${exn} = ${RT}MlException.wrap(_x); (${RT}MlOption.None : ${RT}MlOption<${scrutT}>); };`;
    const vcode = this.switchCode(v, value, n.partial, tc, mode, n);
    const ecases = exns.map(c => ({...c, p: stripException(c.p)}));
    const ecode = this.switchCode(exn, ecases, true, tc, mode, n).replace(/case _: throw new ml2hx\.rt\.MatchFailure\([^;]*\);/, `case _: throw ${exn};`);
    const body = mode === 'value'
      ? `{ ${tryPart} (switch (${opt}) { case ${RT}MlOption.Some(${v}): ${vcode}; case ${RT}MlOption.None: ${ecode}; }); }`
      : `{ ${tryPart} switch (${opt}) { case ${RT}MlOption.Some(${v}): ${vcode} case ${RT}MlOption.None: ${ecode} } }`;
    return body;
  }
  tryExpr(n) {
    const x = this.temp('x'), e = this.temp('e');
    const cases = n.cases;
    const handler = this.switchCode(e, cases, true, null, 'value', n).replace(/case _: throw new ml2hx\.rt\.MatchFailure\([^;]*\);/, `case _: throw ${x};`);
    return `(try ${this.value(n.e)} catch (${x}:haxe.Exception) { var ${e} = ${RT}MlException.wrap(${x}); ${handler}; })`;
  }
  tuplePattern(p, arity) {
    if (p.k === 'value') return this.tuplePattern(p.p, arity);
    if (p.k === 'tuple') {
      const parts = p.args.map(a => this.pattern(a));
      return {pat: `[${parts.map(x => x.pat).join(', ')}]`, guard: parts.map(x => x.guard).filter(Boolean).join(' && ') || null, pre: parts.map(x => x.pre).filter(Boolean).join(' ')};
    }
    if (p.k === 'any') return {pat: `[${Array(arity).fill('_').join(', ')}]`};
    if (p.k === 'or') {
      const a = this.tuplePattern(p.a, arity), b = this.tuplePattern(p.b, arity);
      if (a.guard || b.guard || a.pre || b.pre) this.fail(p, 'or-pattern with conditions');
      return {pat: `${a.pat} | ${b.pat}`};
    }
    this.fail(p, `tuple scrutinee pattern ${p.k}`);
  }
  // A pattern as a Haxe pattern. Returns {pat, guard?, pre?}: a guard for
  // tests Haxe patterns cannot express, statements binding after the match.
  pattern(p) {
    switch (p.k) {
      case 'value': return this.pattern(p.p);
      case 'any': return {pat: '_'};
      case 'var': {
        const name = this.orNames?.get(p.id) ?? this.fresh(identName(p.id));
        this.ids.set(p.id, {kind: 'local', name});
        return {pat: name};
      }
      case 'alias': {
        const inner = this.pattern(p.p);
        const name = this.orNames?.get(p.id) ?? this.fresh(identName(p.id));
        this.ids.set(p.id, {kind: 'local', name});
        return {...inner, pat: inner.pat === '_' ? name : `${name} = ${inner.pat}`};
      }
      case 'const': {
        if (p.c.k === 'int') { const b = BigInt(p.c.v); if (b > 0x7fffffffn || b < -0x7fffffffn) this.fail(p, 'integer pattern outside 32 bits'); return {pat: `${RT}Int63.patternKey(_) => ${b < 0n ? `(${p.c.v})` : p.c.v}`}; }
        if (p.c.k === 'float') return {pat: `${RT}Float64.eq(_, ${this.constant(p.c, p)}) => true`};
        return {pat: this.constant(p.c, p)};
      }
      case 'tuple': return this.join(p.args.map(a => this.pattern(a)), parts => `{${parts.map((x, i) => `v${i}: ${x}`).join(', ')}}`);
      case 'record': return this.join(p.fields.map(f => this.pattern(f.p)), parts => `{${parts.map((x, i) => `${this.fieldName(p.fields[i].lbl)}: ${x}`).join(', ')}}`);
      case 'array': return this.join(p.args.map(a => this.pattern(a)), parts => `[${parts.join(', ')}]`);
      case 'or': {
        // Both sides bind the same identifiers (the typer alpha-renames).
        const a = this.pattern(p.a);
        // Both sides bind the same names (Haxe requires it).
        const savedOr = this.orNames;
        this.orNames = new Map([...(savedOr ?? []), ...patternVars(p.a).map(v => [v.id, this.ids.get(v.id)?.name])]);
        const b = this.pattern(p.b);
        this.orNames = savedOr;
        if (a.guard || b.guard || a.pre || b.pre) this.fail(p, 'or-pattern needing a guard');
        return {pat: `${a.pat} | ${b.pat}`};
      }
      case 'lazy': { const inner = this.pattern(p.p); return {...inner, pat: `_.force() => ${inner.pat}`}; }
      case '$intkey': return {pat: p.v};
      case '$subject': {
        // A variable over the keyed subject: the subject's temporary itself
        // (also in guards).
        this.ids.set(p.id, {kind: 'local', name: p.subject});
        return {pat: '_'};
      }
      case 'construct': return this.ctorPattern(p);
      case 'variant': {
        const hash = hashVariant(p.tag);
        if (!p.arg) return {pat: `_.tag => ${hash}`};
        const inner = this.pattern(p.arg);
        return {...inner, pat: `(${RT}PolyVariant.arg1(_, ${hash}) : ${RT}MlOption<${this.type(p.arg.t, p)}>) => ${RT}MlOption.Some(${inner.pat})`};
      }
      case 'exception': this.fail(p, 'nested exception pattern');
    }
    this.fail(p, `pattern ${p.k}`);
  }
  renameCaptures(pat, boundA, p) {
    // Captures on the right side were freshly named; map them to the left's.
    const vars = patternVars(p);
    let out = pat;
    for (const v of vars) {
      const right = this.ids.get(v.id)?.name, left = boundA.get(v.id)?.name;
      if (right && left && right !== left) out = out.replace(new RegExp(`\\b${right}\\b`, 'g'), left);
    }
    return out;
  }
  join(parts, build) {
    return {pat: build(parts.map(x => x.pat)), guard: parts.map(x => x.guard).filter(Boolean).join(' && ') || null, pre: parts.map(x => x.pre).filter(Boolean).join(' ') || null};
  }
  ctorPattern(p) {
    const c = p.c;
    if (c.ext) {
      const cls = this.exnClass(c.ext, p);
      if (!p.args.length) return {pat: `${RT}Runtime.isInstance(_, ${cls}) => true`};
      const parts = p.args.map(a => this.pattern(a));
      return this.join(parts, xs => `${RT}Runtime.downcast(_, ${cls}) => ${RT}MlOption.Some({${xs.map((x, i) => `v${i}: ${x}`).join(', ')}})`);
    }
    if (c.name === 'true' || c.name === 'false') return {pat: c.name};
    if (c.name === '()') return {pat: '_'};
    if (c.name === '[]' || c.name === '::') {
      if (c.name === '[]') return {pat: `${RT}MlList.Nil`};
      return this.join(p.args.map(a => this.pattern(a)), xs => `${RT}MlList.Cons(${xs.join(', ')})`);
    }
    if (c.type?.p === 'option') {
      if (c.name === 'None') return {pat: `${RT}MlOption.None`};
      return this.join(p.args.map(a => this.pattern(a)), xs => `${RT}MlOption.Some(${xs[0]})`);
    }
    const name = this.ctorRef(c, p);
    if (!p.args.length) return {pat: name};
    return this.join(p.args.map(a => this.pattern(a)), xs => `${name}(${xs.join(', ')})`);
  }

  // ------------------------------------------------------------ objects
  // A class's structure: constructor parameters, class-level lets, fields.
  classParts(ce) {
    const params = [], lets = [];
    let parentNode = null;
    while (ce.k !== 'struct') {
      if (ce.k === 'fun') { params.push(ce); ce = ce.body; }
      else if (ce.k === 'let') { lets.push(ce); ce = ce.body; }
      else if (ce.k === 'constraint') ce = ce.ce;
      else throw new Unsupported(ce, `class expression ${ce.k}`);
    }
    return {params, lets, cs: ce.cs};
  }
  declareClass(c, hx) {
    const parts = this.classParts(c.ce);
    const d = {kind: 'class', hx, decl: c, parts, methods: new Map(), parent: null, arity: parts.params.length};
    for (const f of parts.cs.fields) {
      if (f.k === 'inherit') {
        if (d.parent) this.fail(f, 'multiple inheritance');
        let ce = f.ce, args = [];
        while (ce.k === 'constraint') ce = ce.ce;
        if (ce.k === 'apply') { args = ce.args; ce = ce.fn; while (ce.k === 'constraint') ce = ce.ce; }
        if (ce.k !== 'ident') this.fail(f, `inherit from ${ce.k}`);
        d.parent = this.resolveType(ce.path, f);
        if (d.parent.kind !== 'class') this.fail(f, 'inherit from a non-class');
        d.parentArgs = args; d.parentNode = f;
        for (const [k, v] of d.parent.methods) d.methods.set(k, {...v, inherited: true});
      }
    }
    for (const m of parts.cs.methods) {
      const own = parts.cs.fields.find(f => f.k === 'method' && f.name === m.name);
      const prev = d.methods.get(m.name);
      d.methods.set(m.name, {name: m.name, arity: this.methodArity(m.t), virtual: own ? !!own.virtual : prev?.virtual ?? false, inherited: !own && !!prev, override: !!own && !!prev});
    }
    return d;
  }
  // Instance variables: declared vals, and the class parameters and lets
  // methods use (which OCaml makes instance variables too).
  instvarField(name) { return this.classParams?.get(name) ?? `iv_${valueName(name)}`; }
  // object ... end: an anonymous structure of its methods (and values),
  // self being the structure.
  immediateObject(n) {
    const t = this.t(n.t);
    if (t.k !== 'object') this.fail(n, 'immediate object of no object type');
    const o = this.temp('o');
    const savedSelf = this.selfName, savedParams = this.classParams;
    this.selfName = o;
    this.classParams = new Map();
    for (const v of patternVars(n.cs.self)) this.ids.set(v.id, {kind: 'local', name: o});
    const fields = [];
    for (const f of n.cs.fields) {
      if (f.k === 'val') { fields.push(`iv_${valueName(f.name)}: ${this.value(f.e)}`); continue; }
      if (f.k !== 'method') this.fail(f, `immediate object field ${f.k}`);
      const ft = t.fields.find(x => x.name === f.name);
      const arity = ft ? this.methodArity(ft.t) : 0;
      const sig = this.methodSignature(ft ? ft.t : f.e.t, arity, f);
      const mb = this.methodBody(f.e, arity, sig, f);
      fields.push(`${valueName(f.name)}: function(${mb.params ?? sig.params}):${sig.res} ${mb.body}`);
    }
    this.selfName = savedSelf;
    this.classParams = savedParams;
    return `{ var ${o}:${this.type(n.t, n)} = null; ${o} = cast { ${fields.join(', ')} }; ${o}; }`;
  }
  methodArity(t) { let x = this.t(t); if (x.k === 'poly') x = this.t(x.body); let n = 0; while (x.k === 'arrow') { n++; x = this.t(x.res); } return n; }
  emitClass(c, d) {
    const {params, lets, cs} = d.parts;
    const name = d.hx.split('.').at(-1);
    this.withTypeParams(this.declParams(c, c), tparams => {
      const gen = tparams.length ? `<${tparams.join(', ')}>` : '';
      const members = [], ctor = [], ctorParams = [];
      const saved = new Map(this.ids);
      const savedParams = this.classParams;
      this.classParams = new Map(d.parent ? this.inheritedParams(d.parent) : []);
      // Class parameters and class-level lets become fields.
      for (const p of params) {
        const pname = this.fresh('p');
        ctorParams.push(`${pname}:${this.type(p.p.t, p)}`);
        const bound = this.bindIrrefutable(p.p, pname);
        if (bound === null) this.fail(p, 'refutable class parameter');
        ctor.push(bound);
        for (const x of p.defaults) {
          const f = `cp_${this.fresh(identName(x.id))}`;
          members.push(`var ${f}:${this.type(x.e.t, p)};`);
          ctor.push(`this.${f} = ${this.value(x.e)};`);
          this.ids.set(x.id, {kind: 'local', name: `this.${f}`});
          this.classParams.set(identName(x.id), f); (d.paramFields ??= new Map()).set(identName(x.id), f);
        }
      }
      for (const l of lets) {
        ctor.push(this.bindings({rec: l.rec, bindings: l.bindings}));
        for (const x of l.ivars) {
          const f = `cp_${this.fresh(identName(x.id))}`;
          members.push(`var ${f}:${this.type(x.e.t, l)};`);
          ctor.push(`this.${f} = ${this.value(x.e)};`);
          this.ids.set(x.id, {kind: 'local', name: `this.${f}`});
          this.classParams.set(identName(x.id), f); (d.paramFields ??= new Map()).set(identName(x.id), f);
        }
      }
      for (const id of patternVars(cs.self)) this.ids.set(id.id, {kind: 'local', name: 'this'});
      let superCall = null;
      const parentHx = d.parent ? this.parentType(d) : null;
      const inits = [];
      for (const f of cs.fields) {
        switch (f.k) {
          case 'inherit': {
            const args = d.parentArgs.map(a => a.e ? this.value(a.e) : this.fail(f, 'omitted class argument'));
            superCall = `super(${args.join(', ')});`;
            if (f.super) this.ids.set(`super:${f.super}`, {kind: 'super'});
            break;
          }
          case 'val': {
            const field = `iv_${valueName(f.name)}`;
            if (f.virtual) break;
            const t = this.type(f.e.t, f);
            if (!d.parent || !this.parentHasVal(d.parent, f.name)) members.push(`public var ${field}:${t};`);
            ctor.push(`this.${field} = ${this.value(f.e)};`);
            break;
          }
          case 'method': {
            const info = d.methods.get(f.name);
            const mt = this.methodType(cs, f.name);
            const sig = this.methodSignature(mt, info.arity, f);
            if (f.virtual) { members.push(`abstract public function ${valueName(f.name)}${sig.gen}(${sig.params}):${sig.res};`); break; }
            const mb = this.methodBody(f.e, info.arity, sig, f);
            members.push(`${d.parent && this.parentHasMethod(d.parent, f.name) ? 'override ' : ''}public function ${valueName(f.name)}${sig.gen}(${mb.params ?? sig.params}):${sig.res} ${mb.body}`);
            break;
          }
          case 'initializer': inits.push(this.selfBody(f.e)); break;
        }
      }
      const isAbstract = c.virtual || [...d.methods.values()].some(m => m.virtual);
      const body = [...(superCall ? [superCall] : []), ...ctor, ...inits].join(' ');
      this.decls.push(`${isAbstract ? 'abstract ' : ''}class ${name}${gen}${parentHx ? ` extends ${parentHx}` : ''} {\n${members.map(m => '\t' + m).join('\n')}\n\tpublic function new(${ctorParams.join(', ')}) { ${body} }\n}`);
      this.ids = saved;
      this.classParams = savedParams;
    });
  }
  inheritedParams(p) { return [...(p.parent ? this.inheritedParams(p.parent) : []), ...(p.paramFields ?? [])]; }
  parentType(d) {
    const pn = d.parentNode;
    // The inherited class's type arguments, from the inherit expression's type.
    const p = d.parent;
    if (!p.decl.params.length) return p.hx;
    let ce = pn.ce; while (ce.k === 'constraint' || ce.k === 'apply') ce = ce.k === 'apply' ? ce.fn : ce.ce;
    if (ce.k === 'ident' && ce.targs?.length === p.decl.params.length) return `${p.hx}<${ce.targs.map(t => this.type(t, pn)).join(', ')}>`;
    this.fail(pn, 'inheriting a parameterised class');
  }
  parentHasVal(p, name) { return p.parts.cs.fields.some(f => f.k === 'val' && f.name === name) || (p.parent && this.parentHasVal(p.parent, name)); }
  parentHasMethod(p, name) { return p.parts.cs.fields.some(f => f.k === 'method' && f.name === name && !f.virtual) || (p.parent && this.parentHasMethod(p.parent, name)); }
  methodType(cs, name) { const m = cs.methods.find(x => x.name === name); if (!m) this.fail(cs, `method ${name} without type`); return m.t; }
  methodSignature(t, arity, n) {
    let x = this.t(t), vars = [];
    if (x.k === 'poly') { vars = x.vars.map(v => this.t(v)).filter(v => v.k === 'var').map(v => v.id); t = x.body; }
    const out = {};
    this.withTypeParams(vars.filter(v => !this.tvars.has(v)), tp => {
      const {args, res} = this.arrows(t);
      out.gen = tp.length ? `<${tp.join(', ')}>` : '';
      out.names = args.slice(0, arity).map((_, i) => `a${i}`);
      out.params = args.slice(0, arity).map((a, i) => `a${i}:${this.type(a.t, n)}`).join(', ');
      out.res = arity < args.length ? this.chainType(args.slice(arity), res, n) : this.type(res, n);
      out.vars = vars;
    });
    return out;
  }
  // A method's body: `fun self -> fun a b -> e`; self is `this`.
  methodBody(e, arity, sig, f) {
    return this.withTypeParams(sig.vars.filter(v => !this.tvars.has(v)), () => {
      const fn = funInfo(e);
      const self = fn.params[0];
      for (const v of patternVars(self.p)) this.ids.set(v.id, {kind: 'local', name: 'this'});
      const rest = {params: fn.params.slice(1), arity: fn.arity - 1, body: fn.body};
      if (rest.arity === arity) {
        // Reuse the function machinery with the method's parameter names.
        const node = {...e, t: this.arrows(e.t).args.length > rest.arity ? this.selfStripped(e.t) : e.t};
        const parts = this.functionParts(rest, node, null);
        return {params: parts.params, body: parts.body};
      }
      if (rest.arity === 0) {
        const v = this.value(rest.body ?? {k: 'unsupported', text: 'method cases'});
        return {body: `{ return ${sig.names.reduce((acc, a) => `${acc}(${a})`, `(${v})`)}; }`};
      }
      if (rest.arity < arity) {
        // Fewer parameters than the method type's arrows: the body's closure
        // applied to the rest.
        const t = this.arrows(e.t).args.length > arity ? this.selfStripped(e.t) : e.t;
        const inner = e.params.length > 1 ? {...e, params: e.params.slice(1), t} : e.body.k === "body" ? e.body.e : this.fail(f, "method with cases and fewer parameters");
        const v = this.value(inner);
        return {body: `{ return ${sig.names.reduce((acc, a) => `${acc}(${a})`, `(${v})`)}; }`};
      }
      this.fail(f, `method arity ${rest.arity} differs from its type's ${arity}`);
    });
  }
  selfStripped(t) { const x = this.t(t); return x.k === 'arrow' ? x.res : t; }
  selfBody(e) {
    const fn = funInfo(e);
    for (const v of patternVars(fn.params[0].p)) this.ids.set(v.id, {kind: 'local', name: 'this'});
    return this.stmt(fn.body);
  }
  classOf(t, n) {
    const x = this.t(t);
    if (x.k === 'object' && x.class) return this.resolveType(x.class, n);
    if (x.k === 'constr') { try { const d = this.resolveType(x.path, n); if (d.kind === 'class') return d; } catch (e) {} }
    return null;
  }
  newObject(n) {
    const d = this.resolveType(n.fn.path, n);
    if (d.kind !== 'class') this.fail(n, 'new of a non-class');
    const t = this.type(n.t, n).replace(/^\(.*\) -> /, '');
    const cls = this.classOf(this.resultAfter(n.fn.t, d.arity), n) ? this.type(this.resultAfter(n.fn.t, d.arity), n) : d.hx;
    return this.knownCall(`new ${cls}`, d.arity, n, n.fn, d.arity === 0);
  }
  // obj#m args: a method call with the method's arity (from its class).
  send(s, args, n = null) {
    const name = s.meth.name;
    if (s.meth.ancestor) {
      const call = {k: 'apply', t: n?.t ?? s.t, l: s.l, fn: s, args};
      return this.methodCall(`super.${valueName(name)}`, this.sendArity(s, name), call);
    }
    const d = this.classOf(s.obj.t, s);
    let arity;
    if (d) arity = d.methods.get(name)?.arity ?? this.fail(s, `unknown method ${name}`);
    else {
      const ot = this.t(s.obj.t);
      const f = ot.k === 'object' ? ot.fields.find(x => x.name === name) : null;
      arity = f ? this.methodArity(f.t) : this.fail(s, 'method call on a value of no object type');
    }
    const obj = this.value(s.obj);
    const call = {k: 'apply', t: n?.t ?? s.t, l: s.l, fn: s, args};
    return this.methodCall(`${wrap(obj)}.${valueName(name)}`, arity, call);
  }
  sendArity(s, name) { return this.methodArity(s.t); }
  methodCall(callee, arity, call) {
    if (arity === 0) return call.args.length ? this.applyRest(`${callee}()`, call.args, call) : `${callee}()`;
    return this.knownCall(callee, arity, call, call.fn);
  }
}

// ---------------------------------------------------------------- analyses
// (type a) wrappers: the frontend shows them around the function; the
// function node records the names instead.
function stripNewtypes(n) {
  if (Array.isArray(n)) { for (let i = 0; i < n.length; i++) n[i] = stripNewtypes(n[i]); return n; }
  if (!n || typeof n !== 'object') return n;
  for (const k of Object.keys(n)) if (n[k] && typeof n[k] === 'object') n[k] = stripNewtypes(n[k]);
  if (n.k === 'newtype') { const inner = n.e; (inner.newtypes ??= []).unshift(n.name); return inner; }
  return n;
}
// Parameters of a known function, merging directly nested functions and the
// final `function` cases (a function with a known arity, called uncurried).
export function funInfo(n) {
  const params = [];
  let e = n;
  while (e && e.k === 'fun') {
    for (const p of e.params) params.push({label: p.label, id: p.id, p: p.p, default: p.default, partial: p.partial});
    if (e.body.k === 'cases') { params.push({label: '', id: e.body.param, cases: e.body}); return {params, arity: params.length, body: null}; }
    e = e.body.e;
    if (e.k !== 'fun') break;
  }
  return {params, arity: params.length, body: e};
}
function patternVars(p, out = []) {
  if (!p || typeof p !== 'object') return out;
  if ((p.k === 'var' || p.k === 'alias') && p.id) out.push({id: p.id, t: p.t});
  if (p.k === 'or') { patternVars(p.a, out); return out; }
  for (const k of ['p', 'arg']) if (p[k] && typeof p[k] === 'object') patternVars(p[k], out);
  for (const a of p.args ?? []) patternVars(a, out);
  for (const f of p.fields ?? []) patternVars(f.p, out);
  return out;
}
function intKeyPattern(p) {
  switch (p.k) {
    case 'value': return intKeyPattern(p.p);
    case 'any': case 'var': return true;
    case 'const': return p.c.k === 'int' && BigInt(p.c.v) <= 0x7fffffffn && BigInt(p.c.v) >= -0x7fffffffn;
    case 'or': return intKeyPattern(p.a) && intKeyPattern(p.b);
    case 'alias': return intKeyPattern(p.p) && p.p.k !== 'var';
  }
  return false;
}
function intKeyed(p, subject) {
  switch (p.k) {
    case 'value': return intKeyed(p.p, subject);
    case 'const': return {...p, k: '$intkey', v: BigInt(p.c.v) < 0n ? `(${p.c.v})` : p.c.v};
    case 'var': return {...p, k: '$subject', subject};
    case 'or': return {...p, a: intKeyed(p.a, subject), b: intKeyed(p.b, subject)};
    case 'alias': return {...p, p: intKeyed(p.p, subject)};
  }
  return p;
}
function hasExtractor(p) {
  if (!p || typeof p !== 'object') return false;
  if ((p.k === 'construct' && p.c.ext) || p.k === 'variant' || p.k === 'lazy' || (p.k === 'const' && (p.c.k === 'int' || p.c.k === 'float'))) return true;
  return ['p', 'a', 'b', 'arg'].some(k => hasExtractor(p[k])) || (p.args ?? []).some(hasExtractor) || (p.fields ?? []).some(f => hasExtractor(f.p));
}
function irrefutable(p) {
  switch (p.k) {
    case 'any': case 'var': return true;
    case 'value': case 'alias': return irrefutable(p.p);
    case 'construct': return p.c.type?.p === 'unit';
    case 'tuple': return p.args.every(irrefutable);
    case 'record': return p.fields.every(f => irrefutable(f.p));
  }
  return false;
}
function hasException(p) { return p.k === 'exception' || (p.k === 'or' && (hasException(p.a) || hasException(p.b))); }
function stripException(p) { if (p.k === 'exception') return p.p; throw new Unsupported(p, 'or-pattern mixing values and exceptions'); }
function tupleLike(p, n) { return (p.k === 'tuple' && p.args.length === n) || p.k === 'any' || (p.k === 'or' && tupleLike(p.a, n) && tupleLike(p.b, n)) || (p.k === 'value' && tupleLike(p.p, n)); }
// No observable effects and no reads of mutable state.
function pure(n) {
  if (n.impure) return false;
  switch (n.k) {
    case 'const': case 'fun': case '$var': case '$expr': return true;
    case 'ident': return true;
    case 'construct': case 'tuple': return n.args.every(pure);
    case 'variant': return !n.arg || pure(n.arg);
    case 'field': return pure(n.e) && false;
    default: return false;
  }
}
// The ml2hx.rt.Block view of a record (polymorphic compare and hash).
function blockMethods(fields) {
  const get = fields.length ? `switch i { ${fields.map((f, i) => `case ${i}: ${f};`).join(' ')} case _: null; }` : 'null';
  return `\tpublic function blockTag():Int return 0;\n\tpublic function blockSize():Int return ${fields.length};\n\tpublic function blockField(i:Int):Dynamic return ${get};`;
}
const wrap = s => /^[\w.]+$/.test(s) || /^\((?:[^()]|\([^()]*\))*\)$/.test(s) && !s.startsWith('({') ? s : `(${s})`;
const needsParens = s => !/^[\w.]+$/.test(s);
export function haxeString(s) {
  let out = '"';
  for (const ch of s) {
    const c = ch.charCodeAt(0);
    if (ch === '"') out += '\\"'; else if (ch === '\\') out += '\\\\'; else if (ch === '$') out += '$';
    else if (ch === '\n') out += '\\n'; else if (ch === '\r') out += '\\r'; else if (ch === '\t') out += '\\t';
    else if (c < 32 || c >= 127) out += `\\u${c.toString(16).padStart(4, '0')}`;
    else out += ch;
  }
  return out + '"';
}
// OCaml's hash of a polymorphic variant tag (btype.ml hash_variant).
export function hashVariant(s) {
  let accu = 0;
  for (let i = 0; i < s.length; i++) accu = (Math.imul(223, accu) + s.charCodeAt(i)) | 0;
  accu = accu & ((1 << 31) - 1);
  return accu > 0x3FFFFFFF ? accu - (1 << 31) : accu;
}
