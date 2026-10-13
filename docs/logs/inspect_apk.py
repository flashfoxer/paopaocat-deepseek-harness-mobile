import sys, zipfile
p = sys.argv[1]
z = zipfile.ZipFile(p)
names = z.namelist()
abis = {}
for n in names:
    if n.startswith('lib/'):
        abis[n.split('/')[1]] = abis.get(n.split('/')[1], 0) + 1
print('entries      :', len(names))
print('abis in apk  :', abis)
print('arm64 libs   :', sorted(n.split('/')[-1] for n in names if n.startswith('lib/arm64-v8a/')))
hits = [n for n in names if 'paopaocat_mascot' in n]
print('mascot asset :', hits)
print('mascot bytes :', z.getinfo(hits[0]).file_size if hits else 'MISSING')
print('launcher res :', sorted(n for n in names if 'ic_launcher' in n))
print('experts json :', [n for n in names if 'agency_catalog' in n])
