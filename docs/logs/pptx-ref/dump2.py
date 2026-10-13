import zipfile, io, os
z = zipfile.ZipFile(r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\docs\logs\pptx-ref\ref.pptx")
out = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\docs\logs\pptx-ref"
for n in ["ppt/slideLayouts/slideLayout2.xml","ppt/slideLayouts/_rels/slideLayout2.xml.rels",
          "ppt/slideMasters/slideMaster1.xml","ppt/slideMasters/_rels/slideMaster1.xml.rels",
          "ppt/theme/theme1.xml","ppt/notesMasters/notesMaster1.xml","ppt/presProps.xml","ppt/viewProps.xml","ppt/tableStyles.xml"]:
    fn = os.path.join(out, n.replace("/","__"))
    with io.open(fn, "w", encoding="utf-8") as f:
        f.write(z.read(n).decode("utf-8"))
    print(fn)
