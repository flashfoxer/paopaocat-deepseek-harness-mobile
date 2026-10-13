import zipfile, re
z = zipfile.ZipFile(r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\docs\logs\pptx-ref\ref.pptx")
def show(n, limit=3000):
    print("="*20, n, "="*20)
    t = z.read(n).decode("utf-8", "replace")
    print(t[:limit])
for n in ["_rels/.rels","ppt/presentation.xml","ppt/_rels/presentation.xml.rels",
          "ppt/slides/slide1.xml","ppt/slides/_rels/slide1.xml.rels",
          "ppt/notesSlides/notesSlide1.xml","ppt/notesSlides/_rels/notesSlide1.xml.rels",
          "ppt/notesMasters/_rels/notesMaster1.xml.rels",
          "ppt/slideLayouts/slideLayout2.xml","ppt/slideLayouts/_rels/slideLayout2.xml.rels",
          "ppt/slideMasters/_rels/slideMaster1.xml.rels"]:
    show(n)
