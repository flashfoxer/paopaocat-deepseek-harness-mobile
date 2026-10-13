#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
知识库合规扫描 —— 纯本地、流式、低内存，不联网、不调用任何 API。

用途：对用户自行下载的 zhwiki-cn 全量包（或任意同格式知识库）做关键词体检，
      输出命中条目数与上下文样本。

用法：
    python3 tools/kb-compliance-scan.py <kb.json>
    python3 tools/kb-compliance-scan.py <kb.json> --json > report.json

数据格式：JSON 数组，每项 {"completion": "<正文>", "source": "<来源>"}。
脚本按行流式读取（每行一个字段），因此 500 MB 包只需 <100 MB 内存、约 12 秒。

【重要】关键词命中 ≠ 违规内容。中文分词歧义极多（例：「台独」命中「平台独家」、
「港独」命中「香港独资」、「占中」命中「占中国人口」）。命中数是线索，
必须逐个看上下文才能定性 —— 本脚本会打印每条命中词的上下文样本。

【重要·反面同样成立】关键词**零命中 ≠ 内容合规**。2026-10-09 的实测教训：
本脚本对原先随包的 400 条样例（中文维基 2023-07 快照前 400 条）的 41 个高危词
**全部 0 命中**，但把同样 400 条**逐条通读**却找出 5 条不宜预置的内容
（「键盘政治」「西沽堂」「囡囡(电影)」「Unbalance」「郑萃雯」）—— 它们一个
高危词都不含。所以：本脚本只能用来**缩小范围**，不能当作合规结论；
要下结论必须逐条读。正因如此，App 已按用户要求取消内置样本。
"""

import argparse
import collections
import json
import sys
import time

# 六个泛化风险类别（用于判断整体内容画像）
CATEGORIES = {
    "政治/历史": ["共产党", "国民党", "中共", "六四", "天安门", "文革", "文化大革命",
                  "台独", "台湾独立", "藏独", "疆独", "法轮功", "民主运动", "镇压",
                  "屠杀", "起义", "叛乱", "政变", "独裁", "殖民", "侵略", "抗日",
                  "内战", "革命", "社会主义", "资本主义", "异议", "封锁", "审查"],
    "色情/成人": ["性交", "色情", "裸", "卖淫", "妓女", "情色", "性行为", "淫", "娼",
                  "性爱", "成人影片", "AV女优", "乳头", "生殖器"],
    "暴力/恐怖": ["恐怖袭击", "爆炸", "枪击", "谋杀", "杀人", "自杀", "刺客", "暗杀",
                  "酷刑", "夷三族", "凌迟", "斩首", "处决", "屠杀", "绑架", "暴动",
                  "血腥", "战争罪"],
    "宗教/邪教": ["邪教", "异端", "邪说", "教会", "教皇", "伊斯兰", "穆斯林", "圣战",
                  "佛教", "道教", "基督教", "天主教", "东正教", "犹太", "清真", "寺院",
                  "庙宇", "灵魂", "轮回"],
    "违法/成瘾": ["毒品", "海洛因", "冰毒", "大麻", "鸦片", "赌博", "赌场", "枪支",
                  "军火", "走私", "贩毒", "吸毒", "洗钱", "诈骗", "传销", "黑社会", "帮派"],
    "健康/医疗": ["艾滋病", "HIV", "癌症", "肿瘤", "精神病", "抑郁症", "安乐死", "堕胎",
                  "疫苗", "瘟疫", "传染病", "疫情"],
}

# 中国大陆分发语境下真正会被点名的专指词（这些才能定性，不看泛化类别）
HIGH_RISK = [
    "六四", "天安门", "法轮功", "台独", "台湾独立", "藏独", "疆独", "港独", "达赖喇嘛",
    "刘晓波", "吾尔开希", "占领中环", "雨伞运动", "反送中", "反修例", "逃犯条例", "国安法",
    "再教育营", "东突厥斯坦", "活摘", "退党", "民主墙", "民主女神", "维权律师", "良心犯",
    "颠覆国家政权", "分裂国家", "赵紫阳", "胡耀邦", "薄熙来", "周永康", "令计划", "郭文贵",
    "艾未未", "陈光诚", "高智晟", "铜锣湾书店", "元朗袭击", "毛泽东", "习近平", "中华民国",
]

SNIPPET = 22  # 上下文左右各取多少字符
# 备选正文字段名：不同来源的包用的键不一样，按顺序探测
FIELD_CANDIDATES = ("completion", "text", "content", "instruction", "output")


def logical_head(raw, n=40):
    """取开篇 n 个「真实字符」。

    正文在 JSON 里是转义后的形式：\\n 占 2 个原始字符但只算 1 个字符。
    直接切 raw[:40] 会在开头有转义时少看一两个字，导致漏判，这里按逻辑字符数切。
    """
    out = []
    i, size = 0, len(raw)
    while i < size and len(out) < n:
        c = raw[i]
        if c == "\\" and i + 1 < size:
            nxt = raw[i + 1]
            if nxt == "u" and i + 5 < size:
                out.append("?")
                i += 6
                continue
            out.append(" " if nxt == "n" else nxt)
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def detect_field(path):
    """探测正文所在字段名。行式 JSON 里每个字段独占一行，按出现次数判断。"""
    counts = collections.Counter()
    with open(path, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            if i > 200000:
                break
            s = line.lstrip()
            if not s.startswith('"'):
                continue
            key = s[1:s.find('"', 1)]
            if key in FIELD_CANDIDATES:
                counts[key] += 1
    for key in FIELD_CANDIDATES:
        if counts[key]:
            return key
    return None


def scan(path, field=None):
    """流式扫描，返回统计结果。"""
    if field is None:
        field = detect_field(path)
    if field is None:
        raise SystemExit("未能在 %s 中找到正文字段（尝试过 %s）。请用 --field 指定。"
                         % (path, "/".join(FIELD_CANDIDATES)))
    marker = '"%s": "' % field

    started = time.time()
    total = 0
    cat_hits = collections.Counter()
    term_hits = collections.defaultdict(collections.Counter)
    risk_hits = collections.Counter()
    strict_hits = collections.Counter()
    samples = collections.defaultdict(list)
    contexts = collections.defaultdict(list)

    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            s = line.lstrip()
            if not s.startswith(marker):
                continue
            text = s[len(marker):]
            total += 1
            for cat, terms in CATEGORIES.items():
                first = None
                for term in terms:
                    if term in text:
                        term_hits[cat][term] += 1
                        if first is None:
                            first = term
                if first:
                    cat_hits[cat] += 1
                    if len(samples[cat]) < 3:
                        i = text.find(first)
                        samples[cat].append([first, text[max(0, i - SNIPPET):i + len(first) + SNIPPET]
                                             .replace("\\n", " ")])

            for term in HIGH_RISK:
                if term in text:
                    risk_hits[term] += 1
                    if len(contexts[term]) < 4:
                        i = text.find(term)
                        contexts[term].append(text[max(0, i - SNIPPET):i + len(term) + SNIPPET]
                                              .replace("\\n", " "))

            head = logical_head(text)
            for cat, terms in CATEGORIES.items():
                for term in terms:
                    if term in head:
                        strict_hits[cat] += 1
                        break

    return {
        "path": path,
        "field": field,
        "entries": total,
        "seconds": round(time.time() - started, 1),
        "categories": [
            {"name": cat, "entries": cat_hits[cat],
             "ratio": round(cat_hits[cat] * 100.0 / total, 2) if total else 0,
             "top_terms": term_hits[cat].most_common(8),
             "samples": samples[cat]}
            for cat in CATEGORIES
        ],
        "strict": [{"name": cat, "entries": strict_hits[cat]} for cat in CATEGORIES],
        "high_risk": [{"term": t, "entries": risk_hits[t], "contexts": contexts[t]}
                      for t in HIGH_RISK],
    }


def report(r):
    out = sys.stdout
    out.write("文件: %s    正文字段: %s\n" % (r["path"], r["field"]))
    out.write("条目数: %d    耗时: %.1f 秒    内存: 流式（不整包解析）\n"
              % (r["entries"], r["seconds"]))
    out.write("\n=== 类别命中（任一词出现在正文任意位置；含重叠）===\n")
    for c in r["categories"]:
        top = "、".join("%s×%d" % (t, k) for t, k in c["top_terms"])
        out.write("%-10s %7d 条  %5.2f%%   %s\n" % (c["name"], c["entries"], c["ratio"], top))
    out.write("\n=== 主题级命中（敏感词出现在开篇 40 字内）===\n")
    for s in r["strict"]:
        out.write("%-10s %7d 条\n" % (s["name"], s["entries"]))
    out.write("\n=== 高危专指词逐词计数 ===\n")
    zero, nonzero = [], []
    for h in r["high_risk"]:
        (nonzero if h["entries"] else zero).append(h["term"])
    out.write("命中为 0（已清除或本就不含）: %s\n" % ("、".join(zero) or "（无）"))
    out.write("命中 >0（需逐个看上下文定性）:\n")
    for h in r["high_risk"]:
        if not h["entries"]:
            continue
        out.write("  %-12s %6d\n" % (h["term"], h["entries"]))
        for ctx in h["contexts"]:
            out.write("        …%s…\n" % ctx)
    out.write("\n=== 各类别上下文样本 ===\n")
    for c in r["categories"]:
        out.write("[%s]\n" % c["name"])
        for term, ctx in c["samples"]:
            out.write("   〔%s〕…%s…\n" % (term, ctx))
    out.write("\n注意：关键词命中 ≠ 违规内容。中文子串歧义极多（「台独」/「平台独家」、"
              "「港独」/「香港独资」、「占中」/「占中国人口」），\n"
              "      务必看上面的上下文再定性。\n")


def main():
    ap = argparse.ArgumentParser(description="知识库合规扫描（本地、流式、不联网）")
    ap.add_argument("path", help="知识库 JSON 文件路径")
    ap.add_argument("--field", default=None, help="正文字段名（默认自动探测）")
    ap.add_argument("--json", action="store_true", help="输出 JSON 报告而非文本报告")
    args = ap.parse_args()
    result = scan(args.path, args.field)
    if args.json:
        json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    else:
        report(result)


if __name__ == "__main__":
    main()
