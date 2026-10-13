import zipfile, io, sys
from PIL import Image
z = zipfile.ZipFile(sys.argv[1])
pngs = []
for n in z.namelist():
    if n.startswith("res/") and n.endswith(".png"):
        d = z.read(n)
        try:
            im = Image.open(io.BytesIO(d)); im.load()
            pngs.append((n, "%dx%d" % im.size, len(d)))
        except Exception:
            pngs.append((n, "unreadable", len(d)))
xmls = [n for n in z.namelist() if n.startswith("res/") and n.endswith(".xml")]
print("res pngs :", len(pngs), " res xmls:", len(xmls))
wanted = {"108x108", "162x162", "216x216", "324x324", "432x432", "48x48", "72x72", "96x96", "144x144", "192x192"}
hit = [p for p in pngs if p[1] in wanted]
for n, s, b in sorted(hit, key=lambda x: -x[2]):
    print("  iconish:", s, str(b).rjust(7), n)
print("adaptive-foreground sizes present:", sorted({p[1] for p in hit if p[1] in {"108x108","162x162","216x216","324x324","432x432"}}))
print("legacy/round sizes present      :", sorted({p[1] for p in hit if p[1] in {"48x48","72x72","96x96","144x144","192x192"}}))
