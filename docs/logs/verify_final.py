import zipfile, io, sys
from PIL import Image
apk = sys.argv[1]
z = zipfile.ZipFile(apk)
names = z.namelist()

# 1) launcher icons by SIZE (release renames resources)
sizes = {}
for n in names:
    if n.startswith("res/") and n.endswith(".png"):
        try:
            im = Image.open(io.BytesIO(z.read(n))); im.load()
            sizes.setdefault("%dx%d" % im.size, 0)
            sizes["%dx%d" % im.size] += 1
        except Exception:
            pass
want = ["108x108","162x162","216x216","324x324","432x432","48x48","72x72","96x96","144x144","192x192"]
print("icon-size check:", {k: sizes.get(k,0) for k in want})

# 2) new feature strings inside the AOT snapshot (CJK is UTF-16LE!)
lib = z.read("lib/arm64-v8a/libapp.so")
def has(s):
    return (s.encode("utf-8") in lib) or (s.encode("utf-16-le") in lib)
checks = [
    ("首页品牌名", "泡泡猫的DSH"),
    ("用户要求的推广文案", "请帮忙推广一下我的公众号"),
    ("中部提示", "我帮你用泡泡猫的DSH"),
    ("导航:设置", "设置"),
    ("资料库 Tab", "我的资料"),
    ("资料库空态", "暂无文件"),
    ("定时任务空态", "暂无定时任务"),
    ("定时任务引导", "点右上角 + 新建"),
    ("设置-外观", "外观"),
    ("设置-获取模型", "获取模型"),
    ("设置-保存并应用", "保存并应用"),
    ("中文报错 429", "请求太频繁"),
    ("中文报错 401", "API Key 无效或没填"),
    ("服务商 MiMo", "MiMo（小米）"),
    ("服务商 LongCat", "LongCat（美团）"),
    ("保活提示", "后台运行依赖一个常驻通知"),
]
ok = 0
for label, s in checks:
    r = has(s)
    ok += 1 if r else 0
    print("  %s %-22s %s" % ("HIT " if r else "MISS", label, s))
print("strings: %d/%d hit" % (ok, len(checks)))
print("mascot:", [n for n in names if "paopaocat_mascot" in n])
