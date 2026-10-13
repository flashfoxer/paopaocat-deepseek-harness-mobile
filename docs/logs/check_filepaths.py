import zipfile, sys, re
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
print("res xml entries:", [n for n in names if n.startswith("res/") and n.endswith(".xml")][:12])
hit_attach, hit_path = [], []
for n in names:
    if not (n.startswith("res/") or n.startswith("assets/")):
        continue
    try:
        d = z.read(n)
    except Exception:
        continue
    if b"attachments" in d or "attachments".encode("utf-16-le") in d:
        hit_attach.append(n)
    if b"files-path" in d or "files-path".encode("utf-16-le") in d:
        hit_path.append(n)
print("entries containing 'attachments':", hit_attach)
print("entries containing 'files-path' :", hit_path)
