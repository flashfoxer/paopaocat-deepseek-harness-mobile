import zipfile
z = zipfile.ZipFile(r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\dist\dsh-local-arm64-v8a-app-release.apk")
lib = z.read("lib/arm64-v8a/libapp.so")
print("v0.06 in libapp.so:", b"v0.06" in lib)
print("0.0.6 in libapp.so:", b"0.0.6" in lib)
print("0.05 in libapp.so (should be False):", b"0.05" in lib)
