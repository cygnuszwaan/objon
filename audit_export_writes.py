"""Static scan for runtime writes to authored (@export / @export_storage) properties.

Usage (from the project root):  python3 audit_export_writes.py [--json out.json]

Reports, per script: (OWN) assignments or mutating calls on the script's own exports outside the export's
own setter, and (X) writes to a property that is exported by ANY script (receiver.name = ...). X includes
false positives where a built-in node property shares a name with some export (shape.points, sprite.texture).
Limits: regex based; does not see writes through set(), writes to exported Resources mutated in place, or
mutation of an exported array through an alias. Review every hit by hand; a clean scan is not a proof."""
import re, sys, glob, os, json
files=sorted(f for f in glob.glob('**/*.gd',recursive=True) if not f.startswith('__MACOSX') and not f.startswith('.'))
EXP=re.compile(r'@export[\w_]*(?:\([^)]*\))?\s+(?:@\w+\s+)*var\s+(\w+)')
FUNC=re.compile(r'^(\t*)(?:static\s+)?func\s+(\w+)')
OPS=r'(?:=|\+=|-=|\*=|/=|%=|\|=|&=|\^=)(?!=)'
MUT=r'\.(?:append|append_array|push_back|push_front|erase|clear|resize|insert|pop_back|pop_front|remove_at|fill|merge|set)\('
def indent(l): return len(l)-len(l.lstrip('\t'))
exports={}  # file -> {name: line}
for f in files:
    L=open(f,encoding='utf-8',errors='replace').read().split('\n')
    ex={}
    for i,l in enumerate(L):
        m=EXP.search(l)
        if m and not l.lstrip().startswith('#'): ex[m.group(1)]=i
    exports[f]=ex
allnames={}
for f,ex in exports.items():
    for n in ex: allnames.setdefault(n,set()).add(f)
res={}
for f in files:
    L=open(f,encoding='utf-8',errors='replace').read().split('\n')
    ex=exports[f]
    # setter regions
    setter=set()
    for n,i in ex.items():
        base=indent(L[i])
        j=i+1
        while j<len(L) and (L[j].strip()=='' or indent(L[j])>base):
            setter.add(j); j+=1
    # function per line
    fn=[None]*len(L); cur=None; curind=-1; hint=set()
    for i,l in enumerate(L):
        m=FUNC.match(l)
        if m: cur=m.group(2); curind=len(m.group(1))
        elif l.strip() and not l.lstrip().startswith('#') and indent(l)<=curind and not l.lstrip().startswith(('func','static func')): cur=None
        fn[i]=cur
    funcs_with_editor=set(fn[i] for i,l in enumerate(L) if 'is_editor_hint' in l and fn[i])
    own=[]
    for n,di in ex.items():
        pat=re.compile(r'(?<![\w.])(?:self\.)?'+re.escape(n)+r'(?:\[[^\]]*\])?\s*'+OPS)
        mut=re.compile(r'(?<![\w.])(?:self\.)?'+re.escape(n)+MUT)
        for i,l in enumerate(L):
            s=l.strip()
            if i==di or i in setter or s.startswith('#') or s.startswith('var '+n): continue
            code=l.split('#')[0]
            if pat.search(code) or mut.search(code):
                own.append((i+1,n,fn[i],s[:110]))
    cross=[]
    for i,l in enumerate(L):
        code=l.split('#')[0]
        for m in re.finditer(r'([\w\)\]]+)\.(\w+)\s*'+OPS,code):
            recv,name=m.group(1),m.group(2)
            if recv=='self' or name not in allnames: continue
            if allnames[name]=={f} and False: continue
            cross.append((i+1,recv+'.'+name,fn[i],l.strip()[:110]))
    res[f]=dict(n_exports=len(ex),own=own,cross=cross,editor_funcs=sorted(x for x in funcs_with_editor if x))
if '--json' in sys.argv:
    json.dump(res,open(sys.argv[sys.argv.index('--json')+1],'w'),indent=1)
for f in files:
    r=res[f]
    if not (r['own'] or r['cross']): continue
    print('##',f,'(exports: %d)'%r['n_exports'])
    for x in r['own']: print('  OWN  L%d %-26s in %-24s | %s'%(x[0],x[1],x[2],x[3]))
    for x in r['cross']: print('  X    L%d %-26s in %-24s | %s'%(x[0],x[1],x[2],x[3]))
print('scanned %d scripts, %d with exports'%(len(files),sum(1 for f in files if res[f]['n_exports'])))
