import re,sys
src=open(sys.argv[1]).read().splitlines()
out=['.intel_syntax noprefix']
inmacro=False
section=''
parent='top'

def split_args(s):
    args=[]; item=''; quote=False
    for c in s:
        if c=="'": quote=not quote
        if c==',' and not quote: args.append(item.strip());item=''
        else:item+=c
    args.append(item.strip())
    return args

def remove_comment(line):
    quote=False
    for i,c in enumerate(line):
        if c=="'": quote=not quote
        if c==';' and not quote: return line[:i]
    return line
for raw in src:
    line=remove_comment(raw).strip()
    if not line: continue
    if line.startswith('macro ccall '): inmacro=True;continue
    if inmacro:
        if line=='}': inmacro=False
        continue
    if line.startswith('format '):continue
    if line.startswith('public '): out.append('.global '+line[7:]);continue
    if line.startswith('extrn '): out.append('.extern '+line[6:]);continue
    if line.startswith('section '):
        mt=re.search("'([^']+)'",line)
        section=mt.group(1) if mt else '.text'
        out.append('.section '+section);continue
    if re.match(r'^\w+\s*=\s*',line):
        name,val=line.split('=',1)
        out.append('.set '+name.strip()+','+re.sub(r'\b([0-9A-Fa-f]+)h\b',lambda m:'0x'+m.group(1),val.strip()));continue
    if line.startswith('align '):out.append('.balign '+line[6:]);continue
    if re.match(r'^(db|dd|dq)\s+',line):
        k, v = line.split(' ',1)
        out.append('  '+{'db':'.byte','dd':'.long','dq':'.quad'}[k]+' '+ re.sub(r'\b([0-9A-Fa-f]+)h\b',lambda m:'0x'+m.group(1),v))
        continue
    if line.startswith('ccall '):
        fn=line.split()[1]
        out+=['  push rbp','  mov rbp,rsp','  and rsp,-16','  call '+fn,'  mov rsp,rbp','  pop rbp']
        continue
    m=re.match(r'^(\.?[a-zA-Z_][\w.]*)\s+(db|dd|dq|rb|rd|rq)\s+(.*)$',line)
    if m:
        nm,kind,args=m.groups()
        if kind in ['rb','rd','rq']:
            mul={'rb':1,'rd':4,'rq':8}[kind]
            out.append(nm+': .zero ('+args+')*'+str(mul))
            continue
        vals=[]
        for arg in split_args(args):
            if arg.startswith("'") and arg.endswith("'"):
                vals += list(map(str,arg[1:-1].encode()))
            else:
                vals.append(arg)
        out.append(nm+': '+{'db':'.byte','dd':'.long','dq':'.quad'}[kind]+' '+','.join(vals))
        continue
    if line.endswith(':'):
        name=line[:-1].strip()
        if not name.startswith('.'):
            parent=name
            out.append(name+':')
        else:
            out.append('.L_'+parent+'_'+name[1:]+':')
        continue
    # Replace local label names (including relative jumps)
    line=re.sub(r'(?<!\w)\.(\w+)',lambda m:'.L_'+parent+'_'+m.group(1),line)
    # FASM 0AAh style hex values; keep as hex literal
    line=re.sub(r'\b([0-9A-Fa-f]+)h\b',lambda m:'0x'+m.group(1),line)
    # Character constants outside bracket syntax
    line=re.sub(r"'([^']+)'",lambda m:str(ord(m.group(1))) if len(m.group(1))==1 else '0',line)
    # Replace memory ptr word prefix
    line=re.sub(r'\b(byte|word|dword|qword)\s+\[',lambda m:{'byte':'BYTE PTR [','word':'WORD PTR [','dword':'DWORD PTR [','qword':'QWORD PTR ['}[m.group(1)],line)
    # Relative in memory e.g [rel foo+3]
    line=re.sub(r'\[rel\s+([^\]]+)\]',lambda m:'[rip + '+m.group(1)+']',line)
    # Global unindexed symbols need RIP rel for 64 bit; global indexed use absolute disp
    def fix_mem(m):
        inner=m.group(1).strip()
        if 'rip' in inner.lower():return '['+inner+']'
        if re.match(r'^[a-zA-Z_]\w*(?:[+\-][0-9A-Za-z]+)?$',inner):
            # local symbols like history but not registers
            root=inner.split('+')[0].split('-')[0]
            if root.lower() not in {'rax','rbx','rcx','rdx','rsi','rdi','rsp','rbp','r8','r9','r10','r11','r12','r13','r14','r15','eax','ebx','ecx','edx','esi','edi','esp','ebp'}:
                return '[rip + '+inner+']'
        return '['+inner+']'
    line=re.sub(r'\[([^\[\]]+)\]',fix_mem,line)
    out.append('  '+line)
out.append('.section .note.GNU-stack,"",@progbits')
open(sys.argv[2],'w').write('\n'.join(out)+'\n')
