import zipfile, re, io, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
z = zipfile.ZipFile(r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\docs\logs\pptx-ref\ref.pptx")
for n in ["ppt/notesMasters/notesMaster1.xml","ppt/slideLayouts/slideLayout1.xml","ppt/slideLayouts/slideLayout2.xml"]:
    t = z.read(n).decode("utf-8")
    print("="*15, n)
    # 每个 sp 的 cNvPr + ph + xfrm
    for sp in re.findall(r"<p:sp>.*?</p:sp>", t, re.S):
        name = re.search(r'<p:cNvPr id="(\d+)" name="([^"]*)"', sp)
        ph = re.search(r"<p:ph[^>]*/>", sp)
        off = re.search(r'<a:off x="(-?\d+)" y="(-?\d+)"/><a:ext cx="(\d+)" cy="(\d+)"', sp)
        print("  sp id=%s name=%s ph=%s xfrm=%s" % (name.group(1) if name else "?", name.group(2) if name else "?", ph.group(0) if ph else "none", off.groups() if off else "none"))
    print("  clrMap:", re.search(r"<p:clrMap[^>]*/>", t).group(0)[:200] if re.search(r"<p:clrMap[^>]*/>", t) else "none")
print("="*15, "notesMaster 尾部结构")
t = z.read("ppt/notesMasters/notesMaster1.xml").decode("utf-8")
print(t[t.index("</p:spTree>"):][:900])
print("="*15, "slideLayout2 rels")
print(z.read("ppt/slideLayouts/_rels/slideLayout2.xml.rels").decode("utf-8"))
print("="*15, "slideMaster rels")
print(z.read("ppt/slideMasters/_rels/slideMaster1.xml.rels").decode("utf-8"))
