// Typedtree JSON -> Haxe. Unsupported constructs are errors, never Dynamic or stubs.
const keywords = new Set('abstract break case cast catch class continue default do dynamic else enum extends extern false final for function if implements import in inline interface macro new null operator overload override package private public return static super switch this throw true try typedef untyped using var while'.split(' '));
export const camel = s => { const v = s.replace(/_([a-z])/g, (_, c) => c.toUpperCase()); return keywords.has(v) ? `${v}Value` : v; };
const cap = s => { const v = camel(s); return v[0].toUpperCase() + v.slice(1); };
const RT = 'ml2hx.rt.';
export class Unsupported extends Error {
  constructor(n, message) { const l=n?.loc; super(`${l ? `${l.file}:${l.line}:${l.column + 1}: ` : ''}${message}`); this.name='Unsupported'; }
}
export class Emitter {
  constructor(config) { this.config=config; this.serial=0; this.names=new Map(); this.typeNames=new Map(Object.entries(config.types ?? {})); this.vars=new Map(); this.constructors=new Map(); }
  temp() { return `_ml${this.serial++}`; }
  variable(id) { if (!this.names.has(id)) this.names.set(id, this.temp()); return this.names.get(id); }
  typeVars(t, out=new Set()) { if (t?.kind === 'var') out.add(t.id); if(t && typeof t==='object') for (const v of Object.values(t)) { if (Array.isArray(v)) v.forEach(x=>this.typeVars(x,out)); else if (v && typeof v==='object') this.typeVars(v,out); } return out; }
  generic(ids) { return ids.length ? `<${ids.map(id=>this.tv(id)).join(', ')}>` : ''; }
  tv(id) { if (!this.vars.has(id)) this.vars.set(id, `T${this.vars.size}`); return this.vars.get(id); }
  type(t) {
    if (!t) throw new Unsupported(t,'missing type');
    if (t.kind==='var') { if(this.allowedVars && !this.allowedVars.has(t.id))throw new Unsupported(t,'locally polymorphic or existential type variable'); return this.tv(t.id); }
    if (t.kind==='arrow') { if(t.label) throw new Unsupported(t,'labelled function type'); return `(${this.type(t.arg)} -> ${this.type(t.result)})`; }
    if (t.kind==='tuple') { if(t.args.length<2||t.args.length>4)throw new Unsupported(t,'tuple arity '+t.args.length); return `${RT}Tuple${t.args.length}<${t.args.map(a=>this.type(a)).join(', ')}>`; }
    if (t.kind!=='constr') throw new Unsupported(t,`type ${t.kind}: ${t.text ?? ''}`);
    const builtin={int:`${RT}Int63`,int32:'haxe.Int32',int64:'haxe.Int64',string:'String',bool:'Bool',float:'Float',unit:`${RT}Unit`,char:'Int',array:'Array',list:`${RT}MlList`,option:`${RT}MlOption`, 'Stdlib.ref':`${RT}Ref`,ref:`${RT}Ref`};
    const name=builtin[t.path] ?? this.typeNames.get(t.path);
    if (!name) throw new Unsupported(t,`unmapped OCaml type ${t.path}`);
    return name + (t.args.length ? `<${t.args.map(a=>this.type(a)).join(', ')}>` : '');
  }
  int(t) { return t?.kind==='constr' && t.path==='int'; }
  unit(t) { return t?.kind==='constr' && t.path==='unit'; }
  thunk(lines, type=null) { return `(function()${type ? `:${type}` : ""} { ${lines} })()`; }
  value(n) {
    switch(n.kind) {
      case 'int': return `${RT}Int63.parse(${JSON.stringify(n.value)})`;
      case 'int32': return n.value;
      case 'float': { const x=n.value.replaceAll('_',''); if(!/^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(x)) throw new Unsupported(n,`float literal ${x}`); return x.includes('.')||/[eE]/.test(x) ? x : `${x}.0`; }
      case 'char': return `${n.value}`;
      case 'string': { if(!n.bytes)throw new Unsupported(n,'string bytes missing from frontend'); return JSON.stringify(Buffer.from(n.bytes).toString('latin1')); }
      default: throw new Unsupported(n,`constant ${n.kind}`);
    }
  }
  expr(n) {
    if (!n) return `${RT}Unit.value`;
    switch(n.kind) {
      case 'constant': return this.value(n.value);
      case 'ident': {
        if(n.path.id) return this.variable(n.path.id);
        throw new Unsupported(n,`unmapped value ${n.path.name}`);
      }
      case 'open': if(!n.pure)throw new Unsupported(n,'open of an evaluated module');return this.expr(n.expr);
      case 'function': return this.fn(n);
      case 'apply': return this.apply(n);
      case 'construct': {
        if(n.name==='true'||n.name==='false') return n.name;
        if(n.name==='()') return `${RT}Unit.value`;
        if(n.name==='Not_found') return 'core.ds.NotFound.raise()';
        if(n.name==='[]') return `${RT}MlList.Nil`;
        if(n.name==='None') return `${RT}MlOption.None`;
        if(n.name==='Some') return this.ordered(n.args,a=>`${RT}MlOption.Some(${a[0]})`);
        if(n.name==='::') return this.ordered(n.args, a=>`${RT}MlList.Cons(${a.join(', ')})`);
        const c=this.constructors.get(n.name);
        if(!c) throw new Unsupported(n,`constructor ${n.name}`);
        return n.args.length ? this.ordered(n.args,a=>`${c}(${a.join(', ')})`) : c;
      }
      case 'tuple': return this.ordered(n.args,a=>`new ${this.type(n.type)}(${a.join(', ')})`);
      case 'array': return this.ordered(n.args,a=>`[${a.join(', ')}]`);
      case 'field': return `${this.expr(n.expr)}.${camel(n.name)}`;
      case 'setfield': return this.ordered([n.expr,n.value],a=>this.thunk(`${a[0]}.${camel(n.name)} = ${a[1]}; return ${RT}Unit.value;`));
      case 'record': {
        const t=this.type(n.type), base=n.base ? this.temp():null;
        const fields=n.fields.filter(f=>f.expr);
        const args=fields.map(()=>this.temp());
        let pre=fields.map((f,i)=>`var ${args[i]} = ${this.expr(f.expr)};`).reverse().join(' ');
        if(base) pre=`var ${base} = ${this.expr(n.base)}; `+pre;
        const values=n.fields.map(f=>f.expr?args[fields.indexOf(f)]:`${base}.${camel(f.name)}`);
        return this.thunk(`${pre} return new ${t}(${values.join(', ')});`);
      }
      case 'let': return this.thunk(`${this.bindings(n.bindings,n.recursive)} ${this.tail(n.body)}`);
      case 'if': return this.thunk(this.tail(n));
      case 'sequence': return this.thunk(`${this.expr(n.first)}; ${this.tail(n.second)}`);
      case 'while': return this.thunk(`while (${this.expr(n.cond)}) { ${this.expr(n.body)}; } return ${RT}Unit.value;`);
      case 'for': {
        const i=this.variable(n.id), a=this.temp(),b=this.temp();
        return this.thunk(`var ${a} = ${this.expr(n.start)}; var ${b} = ${this.expr(n.stop)}; var ${i} = ${a}; while (${RT}Int63.compare(${i}, ${b}) ${n.up?'<= ':'>= '}0) { ${this.expr(n.body)}; if (${RT}Int63.eq(${i}, ${b})) break; ${i} = ${RT}Int63.${n.up?'add':'sub'}(${i}, ${RT}Int63.ofInt(1)); } return ${RT}Unit.value;`);
      }
      case 'assert': return this.thunk(`if (!(${this.expr(n.expr)})) throw new haxe.Exception(${JSON.stringify(`Assert_failure ${n.loc.file}:${n.loc.line}`)}); return ${RT}Unit.value;`);
      case 'match': return this.thunk(this.match(n));
      case 'try': return this.tryExpr(n);
      default: throw new Unsupported(n,`expression ${n.kind}${n.text ? `: ${n.text}`:''}`);
    }
  }
  // Match the pinned OCaml compiler's right-to-left operand evaluation. Do not
  // rely on any Haxe target's argument or object literal evaluation order.
  ordered(nodes, build) {
    const names=nodes.map(()=>this.temp());
    return this.thunk(`${nodes.map((n,i)=>`var ${names[i]} = ${this.expr(n)};`).reverse().join(' ')} return ${build(names)};`);
  }
  apply(n) {
    if(n.args.some(a=>a.label||!a.expr)) throw new Unsupported(n,'labelled or omitted application argument');
    const args=n.args.map(a=>a.expr), p=n.fn.kind==='ident' ? n.fn.path.name:null;
    if(p==='Stdlib.&&'||p==='Stdlib.||') {
      if(args.length!==2) throw new Unsupported(n,'partially applied short-circuit operator');
      return `(${this.expr(args[0])} ${p.endsWith('&&')?'&&':'||'} ${this.expr(args[1])})`;
    }
    if(p) {
      const b=this.builtin(p,args,n);
      if(b!==null) return b;
    }
    const names=args.map(()=>this.temp()), f=this.temp();
    return this.thunk(`${args.map((a,i)=>`var ${names[i]} = ${this.expr(a)};`).reverse().join(' ')} var ${f} = ${this.expr(n.fn)}; return ${names.reduce((s,a)=>`(${s})(${a})`,f)};`);
  }
  builtin(p,args,n) {
    const simple=p.replace(/^Stdlib\./,'');
    const arities={'+':2,'-':2,'*':2,'/':2,mod:2,'~-':1,'+ .':2,not:1,'=':2,'<>':2,'==':2,'!=':2,'<':2,'>':2,'<=':2,'>=':2,ref:1,'!':1,':=':2,incr:1,decr:1,'Array.make':2,'Array.length':1,'Array.get':2,'Array.set':3,'List.length':1,raise:1};
    const key=p.startsWith('Stdlib.') ? simple : p;
    const arity=arities[key];
    if(arity===undefined) return null;
    if(args.length!==arity) throw new Unsupported(n,`partial builtin ${p}`);
    return this.ordered(args,a=>{
      if(['+','-','*','/','mod','~-'].includes(key)) {
        const op={'+':'add','-':'sub','*':'mul','/':'div',mod:'mod','~-':'neg'}[key];
        return `${RT}Int63.${op}(${a.join(', ')})`;
      }
      if(key==='not') return `!${a[0]}`;
      if(['=','<>','==','!=','<','>','<=','>='].includes(key)) {
        const op={'=':'==','<>':'!=','==':'==','!=':'!='}[key] ?? key;
        if(this.int(args[0].type)) return ['==','!='].includes(op) ? `${op==='!='?'!':''}${RT}Int63.eq(${a.join(', ')})` : `(${RT}Int63.compare(${a.join(', ')}) ${op} 0)`;
        const t=args[0].type;
        if(t.kind==='constr'&&['bool','string','float','char'].includes(t.path)) {
          if(['string','float'].includes(t.path)&&['==','!='].includes(key)) throw new Unsupported(n,'physical equality requires an OCaml heap representation for '+t.path);
          return `(${a[0]} ${op} ${a[1]})`;
        }
        if(['==','!='].includes(key) && t.kind==='constr' && this.typeNames.has(t.path)) return `(${a[0]} ${op} ${a[1]})`;
        throw new Unsupported(n,`unsupported comparison of ${t.path??t.kind}`);
      }
      if(key==='ref') return `new ${RT}Ref(${a[0]})`;
      if(key==='!') return `${a[0]}.value`;
      if(key===':=') return this.thunk(`${a[0]}.value = ${a[1]}; return ${RT}Unit.value;`);
      if(key==='incr'||key==='decr') return this.thunk(`${a[0]}.value = ${RT}Int63.${key==='incr'?'add':'sub'}(${a[0]}.value, ${RT}Int63.ofInt(1)); return ${RT}Unit.value;`);
      if(key==='Array.make') return `${RT}Runtime.arrayMake(${a.join(', ')})`;
      if(key==='Array.length') return `${RT}Int63.ofInt(${a[0]}.length)`;
      if(key==='Array.get') return `${RT}Runtime.arrayGet(${a.join(', ')})`;
      if(key==='Array.set') return `${RT}Runtime.arraySet(${a.join(', ')})`;
      if(key==='List.length') return `${RT}Runtime.listLength(${a[0]})`;
      if(key==='raise') return this.thunk(`throw ${a[0]};`, this.type(n.type));
      throw new Unsupported(n,`builtin ${p}`);
    });
  }
  pattern(p, value) {
    switch(p.kind) {
      case 'value': return this.pattern(p.pattern,value);
      case 'any': return {test:'true',bind:''};
      case 'var': return {test:'true',bind:`var ${this.variable(p.id)} = ${value};`};
      case 'alias': { const x=this.pattern(p.pattern,value); return {test:x.test,bind:`var ${this.variable(p.id)} = ${value}; ${x.bind}`}; }
      case 'tuple': { const ps=p.args.map((p,i)=>this.pattern(p,`${value}.v${i}`)); return {test:ps.map(x=>x.test).join(' && '),bind:ps.map(x=>x.bind).join(' ')}; }
      case 'construct': {
        if(p.name==='()') return {test:'true',bind:''};
        if(p.name==='true'||p.name==='false') return {test:`${value} == ${p.name}`,bind:''};
        // Payload patterns are lowered by switch in match(), not reflected.
        if(!p.args.length) { const c=p.name==='[]'?`${RT}MlList.Nil`:p.name==='None'?`${RT}MlOption.None`:this.constructors.get(p.name); if(c) return {test:`Type.enumIndex(${value}) == Type.enumIndex(${c})`,bind:''}; }
        throw new Unsupported(p,`payload pattern ${p.name}`);
      }
      case 'constant': return {test:this.int(p.type)?`${RT}Int63.eq(${value}, ${this.value(p.value)})`:`${value} == ${this.value(p.value)}`,bind:''};
      default: throw new Unsupported(p,`pattern ${p.kind}`);
    }
  }
  tail(n, self=null, slots=[]) {
    if(n.kind==='let') return `${this.bindings(n.bindings,n.recursive)} ${this.tail(n.body,self,slots)}`;
    if(n.kind==='sequence') return `${this.expr(n.first)}; ${this.tail(n.second,self,slots)}`;
    if(n.kind==='if') return `if (${this.expr(n.cond)}) { ${this.tail(n.then,self,slots)} } else { ${n.else?this.tail(n.else,self,slots):`return ${RT}Unit.value;`} }`;
    if(n.kind==='match') return this.match(n,self,slots);
    if(self && n.kind==='apply' && n.fn.kind==='ident' && n.fn.path.id===self && n.args.length===slots.length && n.args.every(a=>!a.label&&a.expr)) {
      const temps=n.args.map(()=>this.temp());
      return `${n.args.map((a,i)=>`var ${temps[i]} = ${this.expr(a.expr)};`).reverse().join(' ')} ${slots.map((s,i)=>`${s} = ${temps[i]};`).join(' ')} continue;`;
    }
    return `return ${this.expr(n)};`;
  }
  match(n,self=null,slots=[]) {
    const v=this.temp(); let code=`var ${v} = ${this.expr(n.expr)}; `;
    for(const c of n.cases) {
      if(this.hasPayload(c.pattern)) {
        const p=this.switchPattern(c.pattern);
        code+=`switch (${v}) { case ${p}: ${c.guard?`if (${this.expr(c.guard)}) { ${this.tail(c.body,self,slots)} }`:this.tail(c.body,self,slots)} case _: } `;
        continue;
      }
      const p=this.pattern(c.pattern,v);
      code+=`if (${p.test}) { ${p.bind} ${c.guard?`if (${this.expr(c.guard)}) { ${this.tail(c.body,self,slots)} }`:this.tail(c.body,self,slots)} } `;
    }
    return code+`throw new haxe.Exception(${JSON.stringify(`Match_failure ${n.loc.file}:${n.loc.line}`)});`;
  }
  hasPayload(p) { return p.kind==='value'?this.hasPayload(p.pattern):p.kind==='construct'&&p.args.length>0; }
  switchPattern(p) {
    if(p.kind==='value')return this.switchPattern(p.pattern);
    if(p.kind==='any')return '_';
    if(p.kind==='var')return this.variable(p.id);
    if(p.kind==='construct') {
      const name=p.name==='::'?RT+'MlList.Cons':p.name==='[]'?RT+'MlList.Nil':p.name==='Some'?RT+'MlOption.Some':p.name==='None'?RT+'MlOption.None':this.constructors.get(p.name);
      if(!name)throw new Unsupported(p,'unknown pattern constructor '+p.name);
      return name+(p.args.length?'('+p.args.map(x=>this.switchPattern(x)).join(', ')+')':'');
    }
    throw new Unsupported(p,'nested payload pattern '+p.kind);
  }
  tryExpr(n) {
    // Exception identity is shared with the existing port. General payload
    // exceptions will get their own generated representation before enabling.
    const e=this.temp();
    let code=`try { return ${this.expr(n.expr)}; } catch (${e}:Dynamic) { `;
    for(const c of n.cases) {
      const p=c.pattern;
      if(p.kind!=='construct'||p.name!=='Not_found'||p.args.length||c.guard) throw new Unsupported(p,'exception handler');
      code+=`if (Std.isOfType(${e}, core.ds.NotFound)) { ${this.tail(c.body)} } `;
    }
    return this.thunk(code+`throw ${e}; }`);
  }
  fn(n, self=null) {
    const params=[]; let body=n;
    while(body.kind==='function') {
      if(body.cases.length!==1 || body.cases[0].guard) {
        body={...body,cases:[{pattern:{kind:'var',id:body.param,name:body.param,type:body.type.arg},guard:null,body:{kind:'match',loc:body.loc,type:body.type.result,expr:{kind:'ident',path:{id:body.param},type:body.type.arg},cases:body.cases}}]};
      }
      if(body.label) throw new Unsupported(body,'labelled function');
      const c=body.cases[0]; params.push({pattern:c.pattern, type:body.type.arg, result:body.type.result, slot:this.temp(),arg:this.temp()}); body=c.body;
    }
    if(!params.length) {
      if(n.label)throw new Unsupported(n,'labelled function');
      const arg=this.temp(), saved=new Map(this.names);
      this.names.set(n.param,arg);
      const match={kind:'match',loc:n.loc,type:n.type.result,expr:{kind:'ident',path:{id:n.param},type:n.type.arg},cases:n.cases};
      const code=`function(${arg}:${this.type(n.type.arg)}):${this.type(n.type.result)} { ${this.match(match)} }`;
      this.names=saved;return code;
    }
    const saved=new Map(this.names);
    let pre='';
    for(const p of params) { const pat=this.pattern(p.pattern,p.slot); if(pat.test!=='true') pre+=`if (!(${pat.test})) throw new haxe.Exception("Match_failure"); `; pre+=pat.bind+' '; }
    let code=params.map(p=>`var ${p.slot} = ${p.arg};`).join(' ')+` ${self?'while (true) { ':''}${pre}${this.tail(body,self,params.map(p=>p.slot))}${self?' }':''}`;
    for(let i=params.length-1;i>=0;i--) {
      const p=params[i]; code=`function(${p.arg}:${this.type(p.type)}):${this.type(p.result)} { ${i===params.length-1?code:`return ${code};`} }`;
    }
    this.names=saved;
    return code;
  }
  letPattern(p,value) { const x=this.pattern(p,value); if(x.test!=='true' && !/^true(?: && true)*$/.test(x.test))throw new Unsupported(p,'refutable let pattern');return x.bind; }
  bindings(bs,recursive) {
    if(recursive&&(bs.length!==1||bs.some(b=>b.expr.kind!=='function')))throw new Unsupported(bs[0],'recursive values and mutually recursive function groups are unsupported');
    const names=bs.map(b=>{ if(b.pattern.kind!=='var') { if(recursive)throw new Unsupported(b.pattern,'recursive pattern binding'); return this.temp(); } return this.variable(b.pattern.id); });
    let code=recursive?bs.map((b,i)=>`var ${names[i]}:${this.type(b.pattern.type)} = null;`).join(' '):'';
    // Bindings in an OCaml nonrecursive group cannot see each other; resolved IDs
    // from Typedtree keep shadowed names separate. RHS order follows OCaml.
    code+=bs.map((b,i)=>`${recursive?'':`var `}${names[i]}${recursive?'':`:${this.type(b.pattern.type)}`} = ${b.expr.kind==='function'?this.fn(b.expr,recursive?b.pattern.id:null):this.expr(b.expr)};${b.pattern.kind==='var'?'':this.letPattern(b.pattern,names[i])}`).join(' ');
    return code;
  }
  emit(file) {
    this.vars.clear();
    const declarations=file.items.filter(i=>i.kind==='type').flatMap(i=>i.declarations);
    for(const d of declarations) this.typeNames.set(d.name,this.config.types?.[d.name] ?? cap(d.name));
    for(const d of declarations) if(d.kind==='enum') for(const c of d.constructors) this.constructors.set(c.name,`${this.typeNames.get(d.name)}.${c.name}`);
    const bindings=file.items.filter(i=>i.kind==='value').flatMap(i=>i.bindings);
    for(const b of bindings) { if(b.pattern.kind!=='var') throw new Unsupported(b.pattern,'top-level binding'); this.names.set(b.pattern.id,camel(b.pattern.name) + (b.expr.kind==='function' ? '()' : '')); }
    const typeCode=declarations.map(d=>this.declaration(d)).join('\n\n');
    const fields=[];
    for(const i of file.items) {
      if(i.kind==='type'||i.kind==='attribute') continue;
      if(i.kind==='open') {if(!i.pure)throw new Unsupported(i,'open of an evaluated module');continue;}
      if(i.kind!=='value') throw new Unsupported(i,`structure ${i.kind}`);
      if(i.recursive&&(i.bindings.length!==1||i.bindings.some(b=>b.expr.kind!=='function')))throw new Unsupported(i,'recursive values and mutually recursive function groups are unsupported');
      for(const b of i.bindings) {
        const name=camel(b.pattern.name), t=b.pattern.type;
        const generics=[...this.typeVars(t)];
        this.allowedVars=new Set(generics);
        if(generics.length && b.expr.kind!=='function') throw new Unsupported(b,'polymorphic top-level value');
        if(b.expr.kind==='function') {
          // A method constructs the curried closure, avoiding Haxe's prohibition
          // on generic static fields. References call the factory at use sites.
          this.names.set(b.pattern.id,`${name}()`);
          fields.push(`public static function ${name}${this.generic(generics)}():${this.type(t)} { return ${this.fn(b.expr,i.recursive?b.pattern.id:null)}; }`);
        } else fields.push(`public static final ${name}:${this.type(t)} = ${this.expr(b.expr)};`);
      }
    }
    const comments=(file.comments??[]).map(c=>`/*${c.text.replaceAll('*/','* /')}*/`).join('\n');
    return `package ${this.config.package};\n\n// Generated from ${this.config.source}. Do not edit.\n${comments}\n${typeCode}\n\nclass ${this.config.class} {\n${fields.map(s=>'\t'+s).join('\n')}\n}\n`;
  }
  declaration(d) {
    const name=this.typeNames.get(d.name), params=d.params.map(p=>{if(p.kind!=='var')throw new Unsupported(d,'non-variable type parameter');return p.id;});
    this.allowedVars=new Set(params);
    const generics=this.generic(params);
    if(d.kind==='enum') return `enum ${name}${generics} {\n${d.constructors.map(c=>{
      if(c.result||!Array.isArray(c.args)) throw new Unsupported(d,'GADT or inline-record constructor');
      return `\t${c.name}${c.args.length?`(${c.args.map((a,i)=>`v${i}:${this.type(a)}`).join(', ')})`:''};`;
    }).join('\n')}\n}`;
    if(d.kind==='alias') { if(!d.type) throw new Unsupported(d,'abstract type'); return `typedef ${name}${generics} = ${this.type(d.type)};`; }
    if(d.kind==='record') {
      const fields=d.fields.map(f=>`${camel(f.name)}:${this.type(f.type)}`);
      return `class ${name}${generics} {\n${d.fields.map((f,i)=>`\tpublic ${f.mutable?'var':'final'} ${fields[i]};`).join('\n')}\n\tpublic function new(${fields.join(', ')}) {\n${d.fields.map(f=>`\t\tthis.${camel(f.name)} = ${camel(f.name)};`).join('\n')}\n\t}\n}`;
    }
    throw new Unsupported(d,`declaration ${d.kind}`);
  }
}
