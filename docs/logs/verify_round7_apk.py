import io, sys, zipfile
from PIL import Image
apk = sys.argv[1]
z = zipfile.ZipFile(apk)
names = z.namelist()
lib = z.read("lib/arm64-v8a/libapp.so")
def has(s):
    return (s.encode("utf-8") in lib) or (s.encode("utf-16-le") in lib)
checks = [
    ("设置：文件地址", "文件地址"),
    ("设置：关于", "关于"),
    ("设置：求关注文案", "做这个主要是下班晚上才有时间做"),
    ("设置：公众号 ID", "公众号 ID：paopaocat888"),
    ("设置：路径说明", "以上都在 App 私有目录里"),
    ("权限弹层：要执行的内容", "要执行的内容："),
    ("权限弹层：技术细节", "技术细节（原始参数）"),
    ("权限弹层：无详情兜底", "没能取到这一步的详情"),
    ("权限弹层：类别-执行命令", "执行命令"),
    ("权限弹层：类别-修改文件", "修改文件"),
    ("旧 bug 修复：预填即可发送", "预填了内容、右下角却还是麦克风"),
]
ok = 0
for label, s in checks:
    r = has(s)
    ok += 1 if r else 0
    print("  %s %s" % ("HIT " if r else "MISS", label))
print("strings: %d/%d hit" % (ok, len(checks)))
imgs = sorted(n for n in names if "assets/images/" in n)
print("图片资源:", imgs)
for n in imgs:
    im = Image.open(io.BytesIO(z.read(n))); im.load()
    print("   %-58s %s" % (n.split("/")[-1], im.size))
print("ABIs:", sorted({n.split("/")[1] for n in names if n.startswith("lib/")}))
