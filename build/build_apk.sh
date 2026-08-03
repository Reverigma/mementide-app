#!/usr/bin/env bash
# ============================================================
#  「时光记忆」Android APK 构建脚本（Windows / Git Bash）
#
#  用法:
#    bash build/build_apk.sh [versionName] [versionCode]
#    例: bash build/build_apk.sh 1.2 3
#
#  依赖（可用环境变量覆盖，见下方 CONFIG）:
#    - JDK 17
#    - Android SDK: build-tools 34.0.0 + platforms/android-34
#
#  ------------------------------------------------------------
#  Windows / Git Bash 四个关键坑（都踩过，别删这段注释）:
#   1. 必须 export MSYS_NO_PATHCONV=1。否则 MSYS2 会重写传给
#      Windows 程序的路径参数（正斜杠变双斜杠），aapt2 会报
#      "failed to open directory"。
#   2. 所有传给 .exe 的路径一律用反斜杠 Windows 绝对路径。
#   3. 构建工作目录必须是纯 ASCII：aapt2 无法处理含中文的源目录，
#      因此先把源码同步到 $WORK_DIR（默认 C:\tm_build）再构建。
#   4. d8 必须接收「整个 classes.jar」而不是单个 .class 文件，
#      否则内部类（如 MainActivity$Bridge）会漏进 dex，运行时抛
#      NoClassDefFoundError → 开屏闪退。脚本第 [5/8] 步后有自检。
# ============================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1

VERSION_NAME="${1:-1.2}"
VERSION_CODE="${2:-3}"

# ---------------- CONFIG（可用环境变量覆盖）----------------
# 源码根目录 = 本脚本所在目录的上一级
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_POSIX="$(cd "$SCRIPT_DIR/.." && pwd)"

# Android SDK / JDK 位置。请按自己的环境设置，或提前 export。
SDK_WIN="${ANDROID_SDK_WIN:-C:\\Users\\$(whoami)\\.workbuddy\\binaries\\androidbuild\\sdk}"
JDK_WIN="${JDK_WIN:-C:\\Users\\$(whoami)\\.workbuddy\\binaries\\androidbuild\\jdk-17.0.13+11}"

# 纯 ASCII 构建目录（见上方坑 #3）
WORK_WIN="${TM_WORK_WIN:-C:\\tm_build}"
WORK_POSIX="${TM_WORK_POSIX:-/c/tm_build}"

# 签名密钥。默认使用仓库外的本地 keystore（不入库）。
KEYSTORE_PASS="${TM_KEYSTORE_PASS:-timememo123}"
KEYSTORE_ALIAS="${TM_KEYSTORE_ALIAS:-timememo}"
# -----------------------------------------------------------

BT="${SDK_WIN}\\build-tools\\34.0.0"
PLATFORM="${SDK_WIN}\\platforms\\android-34"

AAPT2="${BT}\\aapt2.exe"
ZIPALIGN="${BT}\\zipalign.exe"
APKSIGNER="${BT}\\apksigner.bat"
JAVAC="${JDK_WIN}\\bin\\javac.exe"
JAVA="${JDK_WIN}\\bin\\java.exe"
JAR="${JDK_WIN}\\bin\\jar.exe"
KEYTOOL="${JDK_WIN}\\bin\\keytool.exe"

# 让 apksigner.bat 能找到 java。
# 注意：JAVA_HOME 必须是 Windows 格式（apksigner.bat 是批处理，
# 读不懂 /c/... 这种 POSIX 路径）；PATH 则必须是 POSIX 格式给 bash 用。
# cygpath -m 输出 C:/... 混合格式，Windows 与 bash 都能接受。
export JAVA_HOME="$(cygpath -m "$JDK_WIN")"
export PATH="$(cygpath -u "$JDK_WIN")/bin:$PATH"

BUILD_WIN="${WORK_WIN}\\build"
OUT_WIN="$(cygpath -w "$SRC_POSIX")"

echo "==> 同步源码到 ASCII 构建目录 ($WORK_POSIX)"
# 只清空内容、保留目录本身，避免删除不存在路径时触发安全钩子
clean_dir() {
  if [ -d "$1" ]; then
    find "$1" -mindepth 1 -delete 2>/dev/null || true
  fi
  mkdir -p "$1"
}
for d in android www build/classes build/dex build/res build/apk; do
  clean_dir "$WORK_POSIX/$d"
done

cp -r "$SRC_POSIX/android/." "$WORK_POSIX/android/"
cp -r "$SRC_POSIX/www/."     "$WORK_POSIX/www/"

echo "==> [1/8] aapt2 compile"
"$AAPT2" compile --dir "${WORK_WIN}\\android\\res" \
                 -o "${BUILD_WIN}\\res\\compiled.zip"

echo "==> [2/8] aapt2 link"
"$AAPT2" link \
  -o "${BUILD_WIN}\\apk\\base.apk" \
  --manifest "${WORK_WIN}\\android\\AndroidManifest.xml" \
  -I "${PLATFORM}\\android.jar" \
  --java "${BUILD_WIN}\\classes" \
  -A "${WORK_WIN}\\www" \
  --auto-add-overlay \
  --min-sdk-version 21 \
  --target-sdk-version 34 \
  --version-code "$VERSION_CODE" \
  --version-name "$VERSION_NAME" \
  "${BUILD_WIN}\\res\\compiled.zip"

echo "==> [3/8] javac"
"$JAVAC" -source 8 -target 8 -nowarn \
  -encoding UTF-8 \
  -classpath "${PLATFORM}\\android.jar" \
  -d "${BUILD_WIN}\\classes" \
  -sourcepath "${WORK_WIN}\\android\\java" \
  "${WORK_WIN}\\android\\java\\com\\timememo\\app\\MainActivity.java" 2>&1 | grep -av "^注:" || true

CLASS_COUNT=$(find "$WORK_POSIX/build/classes" -name '*.class' | wc -l)
echo "    编译出 ${CLASS_COUNT} 个 class 文件"

echo "==> [4/8] 打包 classes.jar（含全部内部类）"
"$JAR" cf "${BUILD_WIN}\\classes.jar" -C "${BUILD_WIN}\\classes" com

echo "==> [5/8] d8 dex"
"$JAVA" -cp "${BT}\\lib\\d8.jar" com.android.tools.r8.D8 \
  --lib "${PLATFORM}\\android.jar" \
  --output "${BUILD_WIN}\\dex" \
  --min-api 21 \
  "${BUILD_WIN}\\classes.jar"

# 自检：dex 类数必须 >= 编译产物类数，否则内部类丢失（见坑 #4）
DEX_CLASSES=$("${BT}\\dexdump.exe" -f "${BUILD_WIN}\\dex\\classes.dex" 2>/dev/null \
  | grep -c "Class descriptor" || echo 0)
echo "    dex 内含 ${DEX_CLASSES} 个类"
if [ "$DEX_CLASSES" -lt "$CLASS_COUNT" ]; then
  echo "!! 错误: dex 类数量少于编译产物，内部类可能丢失" >&2
  exit 1
fi

echo "==> [6/8] 打包 dex 进 APK 并对齐"
cp "$WORK_POSIX/build/apk/base.apk" "$WORK_POSIX/build/apk/app-unsigned.apk"
"$JAR" uf "${BUILD_WIN}\\apk\\app-unsigned.apk" -C "${BUILD_WIN}\\dex" classes.dex
"$ZIPALIGN" -f 4 "${BUILD_WIN}\\apk\\app-unsigned.apk" "${BUILD_WIN}\\app-aligned.apk"

echo "==> [7/8] 准备签名密钥"
# keystore 不入库。首次构建自动生成；已有则复用，保证版本可覆盖安装。
if [ ! -f "$WORK_POSIX/build/timememo.keystore" ]; then
  if [ -f "$SRC_POSIX/build/timememo.keystore" ]; then
    cp "$SRC_POSIX/build/timememo.keystore" "$WORK_POSIX/build/timememo.keystore"
    echo "    复用已有 keystore"
  else
    echo "    未找到 keystore，生成新的（注意：与旧版本签名不同，需卸载重装）"
    "$KEYTOOL" -genkeypair -v \
      -keystore "${BUILD_WIN}\\timememo.keystore" \
      -alias "$KEYSTORE_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
      -storepass "$KEYSTORE_PASS" -keypass "$KEYSTORE_PASS" \
      -dname "CN=TimeMemo, OU=Dev, O=TimeMemo, L=, ST=, C=CN"
  fi
fi

echo "==> [8/8] apksigner 签名"
APK_NAME="时光记忆_v${VERSION_NAME}.apk"
"$APKSIGNER" sign \
  --ks "${BUILD_WIN}\\timememo.keystore" \
  --ks-pass "pass:${KEYSTORE_PASS}" \
  --key-pass "pass:${KEYSTORE_PASS}" \
  --out "${OUT_WIN}\\${APK_NAME}" \
  "${BUILD_WIN}\\app-aligned.apk"

# 回写 keystore 到源目录（已被 .gitignore 排除）
cp "$WORK_POSIX/build/timememo.keystore" "$SRC_POSIX/build/timememo.keystore"

echo ""
echo "--- 签名校验 ---"
"$APKSIGNER" verify -v "${OUT_WIN}\\${APK_NAME}" | head -5

echo ""
echo "=========================================="
echo "  构建成功: ${APK_NAME}"
ls -lh "$SRC_POSIX/$APK_NAME" | awk '{print "  大小: "$5}'
echo "=========================================="
