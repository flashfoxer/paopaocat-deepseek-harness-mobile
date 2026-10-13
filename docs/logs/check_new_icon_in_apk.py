import io, sys, zipfile
from PIL import Image
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
print("in-app logo:", [n for n in names if "paopaocat_logo" in n])
print("old mascot still there:", [n for n in names if "paopaocat_mascot" in n])
found = []
for n in names:
    if n.startswith("res/") and n.endswith(".png"):
        try:
            im = Image.open(io.BytesIO(z.read(n))); im.load()
        except Exception:
            continue
        if im.size in ((192, 192), (432, 432), (48, 48)):
            cols = sorted(im.convert("RGB").resize((32, 32)).getcolors(1024), reverse=True)[:2]
            found.append((n, im.size, [(c, "#%02x%02x%02x" % col) for c, col in cols]))
for n, sz, cols in found[:6]:
    print("  %-18s %-10s %s" % (n, sz, cols))
print("候选张数:", len(found))
