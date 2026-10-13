# -*- coding: utf-8 -*-
"""把公众号文章 Markdown 排成"自带图片、双击可看"的 HTML。

为什么这么做：
  * 用户要拿去别的平台发布，所以做成**单文件、图片 base64 内嵌** ——
    换电脑、换目录都不会缺图，浏览器里全选复制也能把图带过去。
  * 全部用**行内样式**：公众号/多数富文本编辑器会丢掉 <style> 块，行内样式才活。
  * 图片先压到 720px 宽 + JPEG，避免 HTML 变成几十兆。

用法：C:\\Python314\\python.exe install\\md_to_wechat_html.py
"""
import base64
import io
import json
import os
import re
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _arg(name, default=None):
    """取 `--name value` 形式的参数（本脚本够用，不引 argparse）。"""
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


# 默认还是那篇预览版文章；新文章用 `--md/--title/--digest` 覆盖，
# 这样同一条发布链路可以复用到每一版（0.14 紧急更新就是这么发的）。
MD = _arg("--md", os.path.join(ROOT, "docs", "公众号-泡泡猫DSH预览版.md"))
HTML = _arg("--out-html", os.path.join(ROOT, "docs", "公众号-泡泡猫DSH预览版.html"))
# 给公众号 API 用的两份产物：
#   * 正文片段（只有 body，图片位置是 {{IMG1}} 这种占位符）
#   * 占位符 → 本地图片路径 的对照表
# 为什么要这样：公众号正文里的图片必须是**微信自己域名**下的 URL，
# 所以流程是"先把正文发上去、拿到 URL、再回填占位符、最后建草稿"。
WECHAT_CONTENT = os.path.join(ROOT, "docs", "wechat-content.html")
WECHAT_IMAGES = os.path.join(ROOT, "docs", "wechat-images.json")
# 标题/作者/摘要也落一份给发布脚本读，避免两处各写一份、发出去的是旧标题。
WECHAT_META = os.path.join(ROOT, "docs", "wechat-meta.json")

# 公众号草稿的元信息（标题按用户给的原话）
WECHAT_TITLE = _arg("--title", "重大发布，手机版的智能体，泡泡猫DSH预览版")
WECHAT_AUTHOR = _arg("--author", "泡泡猫")
WECHAT_DIGEST = _arg(
    "--digest",
    "一个完全跑在手机里的 AI 智能体：会话、专家、技能、资料库、定时任务、工作区、"
    "模型接入、附件与语音。预览版已可用，正式版马上发布。",
)

# 品牌色（与 App 一致：深蓝 + 金）
NAVY = "#16203F"
GOLD = "#B8860B"
TEXT = "#3F3F3F"
DIM = "#8A8A8A"

IMG_RE = re.compile(r"^【图(\d+)·(.+?)】\s*$")
PATH_RE = re.compile(r"`([^`]+)`")


def embed(path, target_w=720, quality=85):
    """把本地图片压成 720 宽的 JPEG data URI。"""
    p = os.path.join(ROOT, "docs", path.replace("\\", "/"))
    if not os.path.exists(p):
        return None, 0
    im = Image.open(p)
    im.load()
    if im.mode in ("RGBA", "LA", "P"):
        bg = Image.new("RGB", im.size, (255, 255, 255))
        im = im.convert("RGBA")
        bg.paste(im, mask=im.getchannel("A"))
        im = bg
    else:
        im = im.convert("RGB")
    if im.width > target_w:
        im = im.resize((target_w, round(im.height * target_w / im.width)), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=quality, optimize=True, progressive=True)
    raw = buf.getvalue()
    return "data:image/jpeg;base64," + base64.b64encode(raw).decode("ascii"), len(raw)


def inline(text):
    """**粗体** / `代码` / *斜体* → 行内样式 HTML。"""
    text = re.sub(r"\*\*(.+?)\*\*",
                  r'<strong style="color:%s;">\1</strong>' % NAVY, text)
    text = re.sub(r"`([^`]+)`",
                  r'<code style="background:#F5F5F5;padding:1px 5px;border-radius:3px;'
                  r'font-size:14px;color:#C7254E;">\1</code>', text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", text)
    return text


def main():
    wechat = "--wechat" in sys.argv
    with open(MD, encoding="utf-8") as f:
        lines = f.read().split("\n")

    out = []
    img_index = []          # (序号, 说明, 原路径, 字节数)
    missing = []
    body_only = []          # --wechat 模式：只留 body，图片用占位符

    # 「> 开头」的行是**写给作者的备注**（配图路径、行文口径、发布说明），
    # 一律不进正文 —— 之前只跳过"文章最前面那一段"，结果标题后面的备注
    # （`# 标题` 之后跟着 `>` 的行）会被当成正文段落发出去（实测发现）。
    # 现在改成：任何位置的 `>` 行都不进正文/HTML。
    for raw in lines:
        line = raw.rstrip()
        if not line:
            continue
        if line.startswith(">"):
            continue

        m = IMG_RE.match(line)
        if m:
            n, desc = m.group(1), m.group(2)
            pm = PATH_RE.search(desc)
            path = pm.group(1) if pm else ""
            label = PATH_RE.sub("", desc).strip().rstrip("：:").strip()
            if wechat:
                if not os.path.exists(os.path.join(ROOT, "docs", path.replace("\\", "/"))):
                    missing.append(path)
                    continue
                img_index.append((n, label, path, 0))
                out.append(
                    '<p style="margin:22px 0 6px;">'
                    '<img src="{{IMG%s}}" style="width:100%%;max-width:100%%;'
                    'display:block;" /></p>'
                    '<p style="text-align:center;color:%s;font-size:13px;margin:0 0 22px;">'
                    '图 %s · %s</p>' % (n, DIM, n, inline(label))
                )
                continue
            uri, size = embed(path)
            if uri is None:
                missing.append(path)
                out.append('<p style="color:#C00;">（缺图：%s）</p>' % inline(label))
                continue
            img_index.append((n, label, path, size))
            out.append(
                '<p style="margin:22px 0 6px;">'
                '<img src="%s" style="width:100%%;max-width:100%%;border-radius:10px;'
                'display:block;border:1px solid #E8E8E8;" /></p>'
                '<p style="text-align:center;color:%s;font-size:13px;margin:0 0 22px;">'
                '图 %s · %s</p>' % (uri, DIM, n, inline(label))
            )
            continue

        if line.startswith("# "):
            out.append(
                '<h1 style="font-size:23px;line-height:1.5;color:%s;margin:8px 0 6px;'
                'font-weight:700;">%s</h1>' % (NAVY, inline(line[2:]))
            )
            continue
        if line.startswith("### "):
            out.append(
                '<h3 style="font-size:17px;color:%s;margin:26px 0 10px;font-weight:700;'
                'padding-left:10px;border-left:4px solid %s;">%s</h3>'
                % (NAVY, GOLD, inline(line[4:]))
            )
            continue
        if line.startswith("## "):
            out.append(
                '<h2 style="font-size:19px;color:%s;margin:30px 0 12px;font-weight:700;'
                'padding-left:10px;border-left:5px solid %s;">%s</h2>'
                % (NAVY, GOLD, inline(line[3:]))
            )
            continue
        if line.strip() == "---":
            out.append('<hr style="border:none;border-top:1px dashed #D8D8D8;margin:26px 0;" />')
            continue
        if line.startswith("- "):
            out.append(
                '<p style="font-size:16px;line-height:1.9;color:%s;margin:6px 0 6px 4px;">'
                '· %s</p>' % (TEXT, inline(line[2:]))
            )
            continue

        # 普通段落
        out.append(
            '<p style="font-size:16px;line-height:1.9;color:%s;margin:14px 0;'
            'letter-spacing:0.3px;">%s</p>' % (TEXT, inline(line))
        )

    body = "\n".join(out)

    # ---- 公众号 API 模式的产物：正文片段 + 图片对照表 ----
    if wechat:
        with open(WECHAT_CONTENT, "w", encoding="utf-8") as f:
            f.write(body)
        with open(WECHAT_IMAGES, "w", encoding="utf-8") as f:
            json.dump(
                [{"n": n, "path": path, "label": label} for n, label, path, _ in img_index],
                f,
                ensure_ascii=False,
                indent=1,
            )
        with open(WECHAT_META, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "title": WECHAT_TITLE,
                    "author": WECHAT_AUTHOR,
                    "digest": WECHAT_DIGEST,
                    "source": os.path.relpath(MD, ROOT).replace("\\", "/"),
                },
                f,
                ensure_ascii=False,
                indent=1,
            )
        print("公众号正文片段: %s（%d 字，%d 个 {{IMGn}} 占位符）"
              % (WECHAT_CONTENT, len(body), len(img_index)))
        print("图片对照表  : %s" % WECHAT_IMAGES)
        print("草稿元信息  : %s" % WECHAT_META)
        print("草稿标题    : %s" % WECHAT_TITLE)
        print("草稿作者    : %s / 摘要 %d 字" % (WECHAT_AUTHOR, len(WECHAT_DIGEST)))
        if missing:
            print("!! 缺图: %s" % missing)
            return 1
        return 0

    html = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>%s</title>
</head>
<body style="margin:0;padding:0;background:#F2F3F5;">
<div style="max-width:677px;margin:0 auto;background:#FFFFFF;padding:26px 18px 40px;
     font-family:-apple-system,BlinkMacSystemFont,'PingFang SC','Microsoft YaHei',
     'Helvetica Neue',Arial,sans-serif;">
%s
<hr style="border:none;border-top:1px dashed #D8D8D8;margin:26px 0;" />
<p style="font-size:13px;color:%s;line-height:1.8;text-align:center;">
本文截图均为实机拍摄，未做美化。<br/>%s · %s
</p>
</div>
</body>
</html>
""" % (WECHAT_TITLE, body, DIM, WECHAT_AUTHOR, WECHAT_TITLE)

    with open(HTML, "w", encoding="utf-8") as f:
        f.write(html)

    print("HTML:", HTML, "%.2f MB" % (os.path.getsize(HTML) / 1024 / 1024))
    print("内嵌图片 %d 张：" % len(img_index))
    for n, label, path, size in img_index:
        print("  图%s %-14s %-46s %6.1f KB" % (n, label, path, size / 1024))
    if missing:
        print("!! 缺图（正文里留了占位）:", missing)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
