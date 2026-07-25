import struct,re
OUT="/mnt/c/Users/adria/AppData/Local/Temp/claude/c--dev-cinnado-s2/117da92c-6626-41f3-83f2-34eee82f19bb/scratchpad"
BIN=OUT+"/atbm_flash2.bin"; VMABASE=0x80000
d=open(BIN,"rb").read()
def foff(vma): return vma-VMABASE
base=0xaa9d4; N=0x45; UNSUP=(0xab0fe,0xab10e)
tbl=[( i+1, (base+struct.unpack("<h",d[foff(base)+i*2:foff(base)+i*2+2])[0])&0xffffffff ) for i in range(N)]
strs={}; i=0; n=len(d)
while i<n:
    if 32<=d[i]<127:
        j=i
        while j<n and 32<=d[j]<127: j+=1
        if j-i>=4: strs[VMABASE+i]=d[i:j].decode("latin1")
        i=j
    else: i+=1
def pimm(s):
    s=s.strip().strip(",").lstrip("#").strip();neg=s.startswith("-")
    if neg:s=s[1:]
    try:v=int(s,16) if s.startswith("0x") else int(s,10)
    except:return None
    return -v if neg else v
RE=re.compile(r"^\s*([0-9a-f]+):\t([0-9a-f ]+?)\t(\S+)(?:\t(.*))?$")
lines={}
for ln in open(OUT+"/atbm_annotated.txt",errors="replace"):
    m=RE.match(ln.rstrip("\n"))
    if m: lines[int(m.group(1),16)]=(m.group(3),(m.group(4) or "").strip())
addrs=sorted(lines)
import bisect
def scan(start,window,follow=True,depth=0):
    reg={}; res=[]
    lo=bisect.bisect_left(addrs,start); 
    for a in addrs[lo:]:
        if a>=start+window: break
        mn,ops=lines[a]; p=[q.strip() for q in ops.split(",")]
        if mn=="sethi" and len(p)>=2:
            v=pimm(p[1]); 
            if v is not None: reg[p[0]]=(v&0xfffff)<<12
        elif mn=="ori" and len(p)>=3 and p[1] in reg:
            v=pimm(p[2])
            if v is not None:
                reg[p[0]]=reg[p[1]]|v
                if reg[p[0]] in strs: res.append(strs[reg[p[0]]])
        elif mn=="jal" and follow and depth<1:
            t=pimm(p[0]) if p else None
            if t is not None:
                sub=scan(t,160,follow=True,depth=depth+1)
                if sub: res.extend(sub)
        if mn.startswith("b") or mn.startswith("j") or mn=="ret5": reg.clear()
    return res
print("| msg_id | hex | handler | label (from referenced strings) |")
print("|---|---|---|---|")
for mid,tgt in tbl:
    if tgt in UNSUP:
        print("| %d | 0x%02x | (unsupported) | - |"%(mid,mid)); continue
    ss=scan(tgt,60)
    # pick the most descriptive string (prefer spi_cmd/MSG/set/get)
    lab=""
    for s in ss:
        if re.search(r"spi_cmd|MSG_|SPICMD|set_|get_|master|pir|battery|wifi|rtc|alarm|dcxo|static|version|1\.2\.5",s,re.I): lab=s; break
    if not lab and ss: lab=ss[0]
    lab=lab.replace("|","/")[:58]
    print("| %d | 0x%02x | 0x%06x | %s |"%(mid,mid,tgt,lab))
