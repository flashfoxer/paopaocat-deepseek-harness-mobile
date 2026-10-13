import zipfile, sys, re
apk = sys.argv[1]
z = zipfile.ZipFile(apk)
lib = z.read("lib/arm64-v8a/libapp.so")
def has(s):
    return (s.encode("utf-8") in lib) or (s.encode("utf-16-le") in lib)
checks = [
    ("问题1 首页新按钮", "开始新会话"),
    ("问题2 模型空态", "还没有可用的模型"),
    ("问题2 说明", "全部来自「设置 → 模型」里你自己的配置"),
    ("问题4 测试并保存", "测试并保存"),
    ("问题4 已就绪", "该模型已就绪"),
    ("问题4 重新测试", "重新测试"),
    ("问题4 修改配置", "修改配置"),
    ("问题4 Key来源", "来自本机安全存储"),
    ("问题5 历史记录", "历史记录"),
    ("问题5 只读回放", "只读回放"),
    ("问题5 时间未知", "时间未知"),
    ("新要求 点击展开会话", "点击展开会话"),
    ("问题3 已取消", "已取消"),
    ("问题3 语音", "已把识别结果填进输入框"),
    ("问题3 附件提示", "确认后点发送"),
    ("问题3 图片说明", "取决于模型的视觉能力"),
    ("问题3 无语音服务", "没有可用的语音识别服务"),
]
ok = 0
for label, s in checks:
    r = has(s)
    ok += 1 if r else 0
    print("  %s %-22s %s" % ("HIT " if r else "MISS", label, s))
print("strings: %d/%d hit" % (ok, len(checks)))
print("has read-transcript script embedded:", has("read-transcript.mjs"))
