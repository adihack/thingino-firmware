import re,os
OUTDIR="/mnt/c/Users/adria/AppData/Local/Temp/claude/c--dev-cinnado-s2/117da92c-6626-41f3-83f2-34eee82f19bb/scratchpad"
BIN=os.path.join(OUTDIR,"atbm_flash2.bin"); BASE=0x400000
DIS=os.path.join(OUTDIR,"atbm_disasm.txt")
def load_strings():
    d=open(BIN,"rb").read(); s={}; i=0;n=len(d)
    while i<n:
        if 32<=d[i]<127:
            j=i
            while j<n and 32<=d[j]<127:j+=1
            if j-i>=4:s[BASE+i]=d[i:j].decode("latin1")
            i=j
        else:i+=1
    return s
strs=load_strings(); straddr=set(strs)
RE=re.compile(r"^\s*([0-9a-f]+):\t([0-9a-f ]+?)\t(\S+)(?:\t(.*))?$")
def pimm(s):
    s=s.strip().strip(",").lstrip("#").strip(); neg=s.startswith("-")
    if neg:s=s[1:]
    try:v=int(s,16) if s.startswith("0x") else int(s,10)
    except:return None
    return -v if neg else v
reg={};consts=[]
for ln in open(DIS,errors="replace"):
    m=RE.match(ln.rstrip("\n"))
    if not m:continue
    mn=m.group(3);ops=(m.group(4) or "").strip();p=[x.strip() for x in ops.split(",")]
    if mn=="sethi" and len(p)>=2:
        v=pimm(p[1]); 
        if v is not None:reg[p[0]]=(v&0xfffff)<<12
    elif mn=="ori" and len(p)>=3 and p[1] in reg:
        v=pimm(p[2])
        if v is not None:reg[p[0]]=reg[p[1]]|v; consts.append(reg[p[0]])
    elif mn=="addi" and len(p)>=3 and p[1] in reg:
        v=pimm(p[2])
        if v is not None:reg[p[0]]=(reg[p[1]]+v)&0xffffffff; consts.append(reg[p[0]])
# candidate pointers that look like RAM app addresses
ptrs=[c for c in consts if 0x40000<=c<0x200000]
print("reconstructed ori/addi consts:",len(consts)," RAM-range ptrs:",len(ptrs))
from collections import Counter
best=None
for K in range(-0x400000,-0x300000,4):
    hits=0
    for P in ptrs:
        if (P-K) in straddr: hits+=1
    if best is None or hits>best[1]:
        best=(K,hits)
print("BEST K=%s (0x%x) hits=%d"%(hex(best[0]),best[0]&0xffffffff,best[1]))
# show a few resolved examples at best K
K=best[0];shown=0
for P in ptrs:
    if (P-K) in straddr:
        print("  ptr 0x%06x -> flash 0x%06x = %r"%(P,P-K,strs[P-K][:40]))
        shown+=1
        if shown>=12:break
