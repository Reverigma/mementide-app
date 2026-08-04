#!/usr/bin/env bash
# ============================================================
#  「念汐 · Mementide」Android APK 构建脚本（Windows / Git Bash）
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
#  Windows / Git Bash 七个关键坑（都踩过，别删这段注释）:
#   1. 必须 export MSYS_NO_PATHCONV=1。否则 MSYS2 会重写传给
#      Windows 程序的路径参数（正斜杠变双斜杠），aapt2 会报
#      "failed to open directory"。
#   2. 所有传给 .exe 的路径一律用反斜杠 Windows 绝对路径。
#   3. 构建工作目录必须是纯 ASCII：aapt2 无法处理含中文的源目录，
#      因此先把源码同步到 $WORK_DIR（默认 C:\mtd_build）再构建。
#   4. d8 必须接收「整个 classes.jar」而不是单个 .class 文件，
#      否则内部类（如 MainActivity$Bridge）会漏进 dex，运行时抛
#      NoClassDefFoundError → 开屏闪退。脚本第 [5/8] 步后有自检。
#   5. 部分精简版 Git Bash / MSYS 环境不带 cygpath 二进制，脚本会崩在
#      路径转换处报 "cygpath: command not found"。下方 to_mixed /
#      to_posix / to_win 提供纯 bash 兜底实现。
#   6. aapt2 link 的 --version-code / --version-name 只在 manifest
#      缺少该属性时才注入，【不会】覆盖已有值。所以必须在拷贝源码后用
#      sed 改写 manifest 副本，否则装到手机上永远显示 v1.0。
#   7. whoami 在加入域/工作组的机器上返回 "HOST\user"，直接拼进
#      C:\Users\ 会得到 C:\Users\HOST\user\... 这种不存在的路径，
#      aapt2.exe 报 "No such file or directory"。优先取 USERPROFILE。
#   8. 默认打正式包（包名 com.mementide.app）。如需换包名 / 品牌，可用环境变量
#      覆盖：MTD_PACKAGE / MTD_APK_PREFIX / MTD_APP_LABEL / MTD_PAGE_TITLE
#      / MTD_KEYSTORE_FILE / MTD_KEYSTORE_PASS / MTD_KEYSTORE_ALIAS。
#      注意：换包名 = 换应用身份，装到手机上是全新一个 App，旧包 localStorage
#      数据带不过来；签名也必须保持一致才能覆盖安装。
# ============================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1

VERSION_NAME="${1:-1.2}"
VERSION_CODE="${2:-3}"

# ---------------- CONFIG（可用环境变量覆盖）----------------
# 源码根目录 = 本脚本所在目录的上一级
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_POSIX="$(cd "$SCRIPT_DIR/.." && pwd)"

# 用户主目录（Windows 格式），见上方坑 #7。
_whoami_raw="$(whoami)"
_user_short="${_whoami_raw##*\\}"          # 剥掉 "HOST\" 前缀
USER_HOME_WIN="${USERPROFILE:-C:\\Users\\${_user_short}}"

# Android SDK / JDK 位置。请按自己的环境设置，或提前 export。
SDK_WIN="${ANDROID_SDK_WIN:-${USER_HOME_WIN}\\.workbuddy\\binaries\\androidbuild\\sdk}"
JDK_WIN="${JDK_WIN:-${USER_HOME_WIN}\\.workbuddy\\binaries\\androidbuild\\jdk-17.0.13+11}"

# 纯 ASCII 构建目录（见上方坑 #3）
WORK_WIN="${MTD_WORK_WIN:-C:\\mtd_build}"
WORK_POSIX="${MTD_WORK_POSIX:-/c/mtd_build}"

# 签名密钥。默认使用仓库外的本地 keystore（不入库）。
KEYSTORE_PASS="${MTD_KEYSTORE_PASS:-mementide123}"
KEYSTORE_ALIAS="${MTD_KEYSTORE_ALIAS:-mementide}"
KEYSTORE_FILE="${MTD_KEYSTORE_FILE:-mementide.keystore}"

# 品牌 / 包名。默认打正式包；打「旧包名过渡版」时用环境变量覆盖，见坑 #8。
BASE_PACKAGE="com.mementide.app"
APP_PACKAGE="${MTD_PACKAGE:-$BASE_PACKAGE}"
APK_PREFIX="${MTD_APK_PREFIX:-Mementide}"
APP_LABEL="${MTD_APP_LABEL:-}"      # 留空 = 沿用 strings.xml
PAGE_TITLE="${MTD_PAGE_TITLE:-}"    # 留空 = 沿用 index.html
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

# ---------------- 路径格式转换（见上方坑 #5）----------------
# 优先用 cygpath；环境里没有时退回纯 bash 实现，避免脚本直接崩掉。
if command -v cygpath >/dev/null 2>&1; then
  to_mixed() { cygpath -m "$1"; }   # C:\a\b -> C:/a/b
  to_posix() { cygpath -u "$1"; }   # C:\a\b -> /c/a/b
  to_win()   { cygpath -w "$1"; }   # /c/a/b -> C:\a\b
else
  to_mixed() { printf '%s' "${1//\\//}"; }
  to_posix() {
    local p="${1//\\//}"
    printf '/%s%s' "$(printf '%s' "${p:0:1}" | tr 'A-Z' 'a-z')" "${p:2}"
  }
  to_win() {
    local p="$1"
    if [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
      printf '%s:\\%s' \
        "$(printf '%s' "${BASH_REMATCH[1]}" | tr 'a-z' 'A-Z')" \
        "${BASH_REMATCH[2]//\//\\}"
    else
      printf '%s' "$p"
    fi
  }
fi

# 让 apksigner.bat 能找到 java。
# 注意：JAVA_HOME 必须是 Windows 格式（apksigner.bat 是批处理，
# 读不懂 /c/... 这种 POSIX 路径）；PATH 则必须是 POSIX 格式给 bash 用。
# 混合格式 C:/... Windows 与 bash 都能接受。
export JAVA_HOME="$(to_mixed "$JDK_WIN")"
export PATH="$(to_posix "$JDK_WIN")/bin:$PATH"

BUILD_WIN="${WORK_WIN}\\build"
OUT_WIN="$(to_win "$SRC_POSIX")"

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

# 把真实版本号注入 manifest 副本。
# 坑：aapt2 link 的 --version-name / --version-code 在 manifest 已含该值时【不会】覆盖，
#     只会在缺失时注入。因此这里直接改写 manifest 副本，保证打出的 APK versionName 正确
#     （否则每个版本包都会带着源码里写死的 1.0 进手机，系统设置里永远显示 v1.0）。
MANIFEST_COPY="$WORK_POSIX/android/AndroidManifest.xml"
sed -i -E "s/android:versionCode=\"[^\"]*\"/android:versionCode=\"$VERSION_CODE\"/" "$MANIFEST_COPY"
sed -i -E "s/android:versionName=\"[^\"]*\"/android:versionName=\"$VERSION_NAME\"/" "$MANIFEST_COPY"
echo "    manifest 版本已注入: name=$VERSION_NAME code=$VERSION_CODE"

# 包名 / 品牌改写（只作用于构建副本，源码不动），见坑 #8
PKG_DIR_POSIX="${APP_PACKAGE//./\/}"
PKG_DIR_WIN="${APP_PACKAGE//./\\}"
if [ "$APP_PACKAGE" != "$BASE_PACKAGE" ]; then
  echo "    切换包名: $BASE_PACKAGE -> $APP_PACKAGE"
  sed -i -E "s/package=\"[^\"]*\"/package=\"$APP_PACKAGE\"/" "$MANIFEST_COPY"
  mkdir -p "$WORK_POSIX/android/java/$PKG_DIR_POSIX"
  mv "$WORK_POSIX/android/java/${BASE_PACKAGE//./\/}/MainActivity.java" \
     "$WORK_POSIX/android/java/$PKG_DIR_POSIX/MainActivity.java"
  sed -i "s/^package ${BASE_PACKAGE//./\\.};/package ${APP_PACKAGE};/" \
     "$WORK_POSIX/android/java/$PKG_DIR_POSIX/MainActivity.java"
fi
if [ -n "$APP_LABEL" ]; then
  echo "    覆盖桌面名称: $APP_LABEL"
  sed -i -E "s|<string name=\"app_name\">[^<]*</string>|<string name=\"app_name\">${APP_LABEL}</string>|" \
    "$WORK_POSIX/android/res/values/strings.xml"
fi
if [ -n "$PAGE_TITLE" ]; then
  echo "    覆盖页面标题: $PAGE_TITLE"
  sed -i -E "s|<title>[^<]*</title>|<title>${PAGE_TITLE}</title>|" "$WORK_POSIX/www/index.html"
  sed -i -E "s|<h1>[^<]*</h1>|<h1>${PAGE_TITLE}</h1>|" "$WORK_POSIX/www/index.html"
fi

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
  "${WORK_WIN}\\android\\java\\${PKG_DIR_WIN}\\MainActivity.java" 2>&1 | grep -av "^注:" || true

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
if [ ! -f "$WORK_POSIX/build/$KEYSTORE_FILE" ]; then
  if [ -f "$SRC_POSIX/build/$KEYSTORE_FILE" ]; then
    cp "$SRC_POSIX/build/$KEYSTORE_FILE" "$WORK_POSIX/build/$KEYSTORE_FILE"
    echo "    复用已有 keystore"
  else
    echo "    未找到 keystore，生成新的（注意：与旧版本签名不同，需卸载重装）"
    "$KEYTOOL" -genkeypair -v \
      -keystore "${BUILD_WIN}\\${KEYSTORE_FILE}" \
      -alias "$KEYSTORE_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
      -storepass "$KEYSTORE_PASS" -keypass "$KEYSTORE_PASS" \
      -dname "CN=Mementide, OU=Dev, O=Mementide, L=, ST=, C=CN"
  fi
fi

echo "==> [8/8] apksigner 签名"
APK_NAME="${APK_PREFIX}-v${VERSION_NAME}.apk"
"$APKSIGNER" sign \
  --ks "${BUILD_WIN}\\${KEYSTORE_FILE}" \
  --ks-pass "pass:${KEYSTORE_PASS}" \
  --key-pass "pass:${KEYSTORE_PASS}" \
  --out "${OUT_WIN}\\${APK_NAME}" \
  "${BUILD_WIN}\\app-aligned.apk"

# 回写 keystore 到源目录（已被 .gitignore 排除）
cp "$WORK_POSIX/build/$KEYSTORE_FILE" "$SRC_POSIX/build/$KEYSTORE_FILE"

echo ""
echo "--- 签名校验 ---"
"$APKSIGNER" verify -v "${OUT_WIN}\\${APK_NAME}" | head -5

echo ""
echo "=========================================="
echo "  构建成功: ${APK_NAME}"
ls -lh "$SRC_POSIX/$APK_NAME" | awk '{print "  大小: "$5}'
echo "=========================================="
