#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
时光记忆 · TimeMemo —— GitHub Release 品牌统一脚本
在【已登录 git 的交互终端】里运行（非沙箱）。本脚本用本机 git 凭据取 token，
不打印/不外泄 token，仅用其调用 GitHub API 完成：
  1) v1.2 / v1.3 Release 的 name 改为「时光记忆 · TimeMemo vX.Y — …」
  2) 两个 Release body 的标题行改为「时光记忆 · TimeMemo vX.Y」
  3) v1.3 替换 APK 附件为带新品牌名的包，并刷新 SHA-256
"""
import subprocess, json, urllib.request, urllib.error, hashlib, sys, re, os

REPO = "Reverigma/timememo-app"
APK = r"C:/Users/yssy/WorkBuddy/test/时光记忆App/build/TimeMemo-v1.3.apk"


def get_token():
    out = subprocess.run(["git", "credential", "fill"],
                         input="protocol=https\nhost=github.com\n",
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1]
    return None


token = get_token()
if not token:
    print("NO TOKEN —— 请在能正常 git push 的交互终端里运行本脚本")
    sys.exit(1)
print("token 已取到（长度 %d，不打印）" % len(token))

H = {"Authorization": "Bearer " + token,
     "Accept": "application/vnd.github+json",
     "User-Agent": "timememo-release"}


def api(method, url, data=None):
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers=H)
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print("HTTP %d: %s" % (e.code, e.read().decode("utf-8")[:500]))
        sys.exit(1)


def get_release(tag):
    return api("GET", "https://api.github.com/repos/%s/releases/tags/%s" % (REPO, tag))


# ---------- v1.2 ----------
r12 = get_release("v1.2")
b12 = r12["body"].replace("# 时光记忆 v1.2", "# 时光记忆 · TimeMemo v1.2")
if b12 == r12["body"]:
    print("⚠ v1.2 body 标题未匹配，未改（当前可能是别的格式）")
api("PATCH", "https://api.github.com/repos/%s/releases/%d" % (REPO, r12["id"]),
    {"name": "时光记忆 · TimeMemo v1.2 — 纪念日与习惯打卡 App", "body": b12})
print("✓ v1.2 Release 已更新（name + 标题）")

# ---------- v1.3 ----------
r13 = get_release("v1.3")
if not os.path.exists(APK):  # 兜底：build 副本缺失时用根目录中文名 APK
    APK = r"C:/Users/yssy/WorkBuddy/test/时光记忆App/时光记忆_v1.3.apk"
sha = hashlib.sha256(open(APK, "rb").read()).hexdigest()
b13 = r13["body"].replace("# 时光记忆 v1.3", "# 时光记忆 · TimeMemo v1.3")
if b13 == r13["body"]:
    print("⚠ v1.3 body 标题未匹配，未改（当前可能是别的格式）")
new_b13 = re.sub(r"(安装包 SHA-256[：:]\s*)`[^`]*`",
                 lambda m: m.group(1) + "`" + sha + "`", b13)
if new_b13 == b13:
    print("⚠ 未在 v1.3 body 找到 SHA-256 行，未刷新（请手动核对）")
else:
    b13 = new_b13
api("PATCH", "https://api.github.com/repos/%s/releases/%d" % (REPO, r13["id"]),
    {"name": "时光记忆 · TimeMemo v1.3 — 纪念日周期重复", "body": b13})
print("✓ v1.3 Release 已更新（name + 标题 + SHA）")

# 删除旧 APK 附件
for a in r13.get("assets", []):
    if a["name"] == "TimeMemo-v1.3.apk":
        api("DELETE", "https://api.github.com/repos/%s/releases/assets/%d" % (REPO, a["id"]))
        print("✓ 旧 APK 附件已删除")

# 上传新 APK
with open(APK, "rb") as f:
    data = f.read()
req = urllib.request.Request(
    "https://uploads.github.com/repos/%s/releases/%d/assets?name=TimeMemo-v1.3.apk"
    % (REPO, r13["id"]),
    data=data, method="POST",
    headers=dict(H, **{"Content-Type": "application/vnd.android.package-archive"}))
with urllib.request.urlopen(req) as r:
    up = json.loads(r.read().decode("utf-8"))
print("✓ 新 APK 已上传：%s（%d 字节）" % (up["name"], up["size"]))

print("\n全部完成 🎉")
