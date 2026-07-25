#!/usr/bin/env python3
# NDS32 app analyzer with CORRECT link base: app linked at VMA = flash - 0x380000.
# adjust-vma=0x80000 makes file offset F -> VMA 0x80000+F = (0x400000+F)-0x380000.
import re,subprocess,os,bisect
OUT="/mnt/c/Users/adria/AppData/Local/Temp/claude/c--dev-cinnado-s2/117da92c-6626-41f3-83f2-34eee82f19bb/scratchpad"
BIN=os.path.join(OUT,"atbm_flash2.bin"); OBJ="/home/adrian/nds32le-elf-objdump"
VMABASE=0x80000     # file off 0 -> VMA 0x80000
DIS=os.path.join(OUT,"atbm_disasm80.txt")
def gen():
    r=subprocess.run([OBJ,"-D","-b","binary","-m","nds32","-EL","--adjust-vma=0x%x"%VMABASE,BIN],capture_output=True,text=True)
    open(DIS,"w").write(r.stdout)
def strings():
    d=open(BIN,"rb").read();s={};i=0;n=len(d)
    while i<n:
        if 32<=d[i]<127:
            j=i
            while j<n and 32<=d[j]<127:j+=1
            if j-i>=4:s[VMABASE+i]=d[i:j].decode("latin1")   # keyed by VMA
            i=j
        else:i+=1
    return s
def pimm(s):
    s=s.strip().strip(",").lstrip("#").strip();neg=s.startswith("-")
    if neg:s=s[1:]
    try:v=int(s,16) if s.startswith("0x") else int(s,10)
    except:return None
    return -v if neg else v
RE=re.compile(r"^\s*([0-9a-f]+):\t([0-9a-f ]+?)\t(\S+)(?:\t(.*))?$")
if not os.path.exists(DIS) or os.path.getsize(DIS)<1000: gen()
strs=strings(); straddr=set(strs)
lines=[]
for ln in open(DIS,errors="replace"):
    m=RE.match(ln.rstrip("\n"))
    if m: lines.append((int(m.group(1),16),m.group(3),(m.group(4) or "").strip(),ln.rstrip("\n")))
print("insns",len(lines),"strings",len(strs))
reg={};const_at={}
for addr,mn,ops,raw in lines:
    p=[x.strip() for x in ops.split(",")]
    try:
        if mn=="sethi" and len(p)>=2:
            v=pimm(p[1])
            if v is not None:reg[p[0]]=(v&0xfffff)<<12;const_at[addr]=reg[p[0]]
        elif mn in("movi","movi55") and len(p)>=2:
            v=pimm(p[1])
            if v is not None:reg[p[0]]=v&0xffffffff;const_at[addr]=reg[p[0]]
        elif mn=="ori" and len(p)>=3 and p[1] in reg:
            v=pimm(p[2])
            if v is not None:reg[p[0]]=reg[p[1]]|v;const_at[addr]=reg[p[0]]
        elif mn=="addi" and len(p)>=3 and p[1] in reg:
            v=pimm(p[2])
            if v is not None:reg[p[0]]=(reg[p[1]]+v)&0xffffffff;const_at[addr]=reg[p[0]]
        elif mn in("mov55","move") and len(p)>=2 and p[1] in reg: reg[p[0]]=reg[p[1]]
        elif mn.startswith("b") or mn=="ret5" or mn=="ret": reg.clear()
    except:pass
xref={};mmio={}
for a,v in const_at.items():
    if v in straddr: xref.setdefault(v,[]).append(a)
    elif 0x16000000<=v<0x17000000: mmio.setdefault(v,[]).append(a)
print("string xrefs",len(xref)," mmio regs",len(mmio))
addrs=[a for a,_,_,_ in lines]; idx={a:i for i,(a,_,_,_) in enumerate(lines)}
def nearest(a):return max(0,bisect.bisect_right(addrs,a)-1)
def annot(a):
    if a in const_at:
        v=const_at[a]
        if v in strs:return "   ; => \"%s\""%strs[v][:60]
        if 0x16000000<=v<0x17000000:return "   ; => MMIO 0x%08x"%v
    return ""
def emit(f,center,before=20,after=2):
    i=idx.get(center,nearest(center))
    for k in range(max(0,i-before),min(len(lines),i+after+1)):
        a,mn,ops,raw=lines[k];f.write(raw+annot(a)+"\n")
    f.write("\n")
t2a={v:k for k,v in strs.items()}
targets=["hal_wdt_cfg_enable"," wdtx = 0x%x","master_wdt_timer_cb","g_master_wdt_timer:0x%x",
 "set master_mode=%d","host alive failed... reboot two devices","HI_SDIO_Host_Reboot",
 "read reboot_flag error.","invalid host alive notify params!","wakeup_host_gpio %d","sleep_host_gpio",
 "[lp_mgr,%d]master_power_on.","[lp_mgr,%d]master_power_off.","[lp_mgr,%d]master_set_status(%d).",
 "[message_mgr,%d]unsupported msg_id:0x%x","CUSTOMER_WDT call, restart CPU","######## WDT %x %x",
 "atbm_sdio_create_keepalive %d not config"]
with open(os.path.join(OUT,"atbm_slices.txt"),"w") as f:
    for t in targets:
        sa=t2a.get(t)
        f.write("################################################ %r\n"%t)
        if sa is None:f.write("  [string not present verbatim]\n\n");continue
        cs=xref.get(sa,[])
        f.write("  str@0x%06x  xrefs(callers): %s\n\n"%(sa,", ".join("0x%06x"%c for c in cs) or "(none)"))
        for c in cs[:3]:emit(f,c)
with open(os.path.join(OUT,"atbm_xref.txt"),"w") as f:
    for sa in sorted(xref):
        f.write("0x%06x %2dx  %r\n"%(sa,len(xref[sa]),strs[sa]))
        for c in xref[sa]:f.write("        <-0x%06x\n"%c)
with open(os.path.join(OUT,"atbm_mmio.txt"),"w") as f:
    for v in sorted(mmio):f.write("REG 0x%08x  @ %s\n"%(v,", ".join("0x%06x"%c for c in sorted(mmio[v]))))
print("wrote slices/xref/mmio")

# ---- appended: full annotated dump + function boundary list ----
def full_annotated():
    with open(os.path.join(OUT,"atbm_annotated.txt"),"w") as f:
        for a,mn,ops,raw in lines:
            f.write(raw+annot(a)+"\n")
    # function starts: lines preceded by ret/j and containing push25, or just push25 after a gap
    with open(os.path.join(OUT,"atbm_funcs.txt"),"w") as f:
        for i,(a,mn,ops,raw) in enumerate(lines):
            if mn=="push25":
                f.write("0x%06x\n"%a)
full_annotated()
print("wrote atbm_annotated.txt + atbm_funcs.txt")
