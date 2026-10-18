// A deterministic layout pass for the emitter's small Haxe grammar. Strings and
// comments are tokens; their contents are never reformatted or interpreted.
export function format(source) {
  let out='', line='', depth=0, i=0;
  const flush=()=>{const s=line.trim();if(s)out+='\t'.repeat(Math.max(0,depth))+s+'\n';line='';};
  while(i<source.length) {
    const c=source[i],next=source[i+1];
    if(c==='"'||c==="'") {
      const quote=c;let token=c;i++;
      while(i<source.length) {const x=source[i++];token+=x;if(x==='\\'&&i<source.length)token+=source[i++];else if(x===quote)break;}
      line+=token;continue;
    }
    if(c==='/'&&(next==='/'||next==='*')) {
      const end=next==='/'?source.indexOf('\n',i+2):source.indexOf('*/',i+2);
      const stop=end<0?source.length:end+(next==='*'?2:0);
      if(line.trim())flush();
      out+='\t'.repeat(Math.max(0,depth))+source.slice(i,stop)+'\n';i=stop;continue;
    }
    if(c==='{') {line+='{';flush();depth++;i++;continue;}
    if(c==='}') {flush();depth--;line='}';i++;if(![';',',',')','>'].includes(source[i]))flush();continue;}
    if(c===';') {line+=';';flush();i++;continue;}
    if(/\s/.test(c)) {if(line&&!line.endsWith(' '))line+=' ';i++;continue;}
    line+=c;i++;
  }
  flush();
  if(depth!==0)throw new Error('unbalanced emitted Haxe');
  return out;
}
