import zipfile, collections, sys
p = r"D:\dev\android-node\app-assets\dsh-runtime.zip"
z = zipfile.ZipFile(p)
names = z.namelist()
print("entries:", len(names))
top = collections.Counter("/".join(n.split("/")[:2]) for n in names if "/" in n)
print("--- top 2 levels (top 25) ---")
for k, v in top.most_common(25):
    print("  %6d  %s" % (v, k))
for kw in ("automation", "dsh-cli", "bin/dsh", "package.json"):
    hits = [n for n in names if kw in n.lower()]
    print("--- %-14s hits=%d ---" % (kw, len(hits)))
    for n in sorted(hits)[:12]:
        print("   ", n)
