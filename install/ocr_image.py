# -*- coding: utf-8 -*-
"""用本机 rapidocr 把截图里的文字读出来（视觉模型被限流时的降级手段）。

结果写 UTF-8 文件，控制台只打 ASCII —— PowerShell 是 cp936，直接 print 中文会乱码。

用法：C:\\Python314\\python.exe install\\ocr_image.py <图片路径> <输出txt>
"""
import os
import sys


def main():
    src = sys.argv[1]
    out = sys.argv[2]
    lines = []

    try:
        from rapidocr_onnxruntime import RapidOCR
    except Exception as e:
        print("rapidocr 导入失败: %s" % e)
        return 2

    engine = RapidOCR()
    result, _ = engine(src)
    if not result:
        lines.append("(没有识别到文字)")
    else:
        # result 的元素形如 [box, text, score]；score 可能是 str，box 是四点坐标
        for item in result:
            try:
                box, text = item[0], item[1]
                raw_score = item[2] if len(item) > 2 else ""
                try:
                    score = float(raw_score)
                except Exception:
                    score = -1.0
                ys = [p[1] for p in box]
                xs = [p[0] for p in box]
                y = int(sum(ys) / len(ys))
                x = int(sum(xs) / len(xs))
            except Exception:
                y = x = 0
                score = -1.0
                text = str(item)
            lines.append("[y=%4d x=%4d s=%.2f] %s" % (y, x, score, text))

    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("ocr lines: %d -> %s" % (len(lines), out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
