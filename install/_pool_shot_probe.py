# -*- coding: utf-8 -*-
import os, subprocess
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
SHOTS = os.path.join(os.path.dirname(os.path.abspath(".")), "theme-screenshots")
SHOTS = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\theme-screenshots"
remote = "/sdcard/pool-pyprobe.png"
r1 = subprocess.run([ADB, "shell", "screencap", "-p", remote], capture_output=True)
print("screencap rc=%s err=%r" % (r1.returncode, r1.stderr[:200]))
local = os.path.join(SHOTS, "pool-pyprobe.png")
if os.path.exists(local): os.remove(local)
r2 = subprocess.run([ADB, "pull", remote, local], capture_output=True)
print("pull rc=%s err=%r" % (r2.returncode, r2.stderr[:200]))
print("exists=%s size=%s" % (os.path.exists(local), os.path.getsize(local) if os.path.exists(local) else -1))
print("SHOTS=%s" % SHOTS)
