import os
import sys

base = sys.argv[1]
bad = 0
checked = 0
for root, dirs, files in os.walk(base):
    for fn in files:
        if not fn.endswith(".dart"):
            continue
        p = os.path.join(root, fn)
        raw = open(p, "rb").read()
        checked += 1
        try:
            text = raw.decode("utf-8")
        except Exception as e:
            print("NOT-UTF8", p, e)
            bad += 1
            continue
        if "\ufffd" in text:
            print("REPLACEMENT-CHAR", p)
            bad += 1
        # mojibake markers: CJK bytes misinterpreted as GBK then re-encoded
        for marker in ("锛", "鈥", "鍒", "鏂", "甯", "璁"):
            if marker in text:
                print("MOJIBAKE", p, marker)
                bad += 1
                break
print("checked=%d bad=%d" % (checked, bad))
