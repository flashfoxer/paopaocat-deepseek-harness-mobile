# -*- coding: utf-8 -*-
"""把 uiautomator dump 里"有文字的节点"打出来，便于看清页面结构。

用法：python install/fix13_ui.py <xml路径>
"""
import re
import sys

path = sys.argv[1]
xml = open(path, encoding="utf-8", errors="replace").read()
for m in re.finditer(r"<node[^>]*?>", xml):
    n = m.group(0)
    cls = re.search(r'class="([^"]*)"', n)
    txt = re.search(r'text="([^"]*)"', n)
    desc = re.search(r'content-desc="([^"]*)"', n)
    b = re.search(r'bounds="([^"]*)"', n)
    clk = re.search(r'clickable="(true|false)"', n)
    sel = re.search(r'selected="(true|false)"', n)
    t = (txt.group(1) if txt else "") or (desc.group(1) if desc else "")
    if not t:
        continue
    print(
        "%-42s click=%-5s sel=%-5s %-22s %s"
        % (
            (cls.group(1) if cls else "?")[-42:],
            clk.group(1) if clk else "?",
            sel.group(1) if sel else "?",
            b.group(1) if b else "",
            t.replace("\n", "\\n")[:100],
        )
    )
