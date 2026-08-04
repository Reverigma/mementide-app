# 念汐 · Mementide

> 极简的纪念日 + 习惯打卡 Android App。数据全部存在手机本地，不联网、无权限、无广告。

一个单文件 HTML 应用 + WebView 原生壳，编译产物只有 **82 KB**。

---

## 功能

**习惯打卡**

- 每日打卡，自动统计连续天数与累计天数
- 最近 7 天热力格，一眼看出断签
- 支持设置未来开始日期，未开始的习惯不可打卡
- 误点可撤销（再点一次取消当天打卡）

**纪念日**

- 三种重复方式：**每年**（生日、周年）、**每月**、**不重复**（考试、截止日）
- 周期性纪念日自动倒数下一次，并显示「第 N 周年」与累计天数
- 闰日与月末自动收敛：2 月 29 日生日在平年按 2/28 计，每月 31 号在 2 月按月末计
- 卡片上点 🔁 随时切换重复方式
- 支持自定义 Emoji 图标

**数据备份**

- 点右上角 💾 导出全部数据为 JSON，可存到手机「下载」目录，也可复制为文本
- 导入支持选择文件或直接粘贴文本，可选**合并**或**覆盖**
- 合并时按「名称 + 日期」对齐条目，打卡记录取并集，换手机不会产生重复项
- 导入前会清洗校验数据，非法内容直接丢弃，不会污染现有记录

**其它**

- 明暗主题切换，与系统状态栏联动
- 今日概览：完成进度、最长连续、最近纪念日
- 数据存于 `localStorage`，卸载 App 才会清除

---

## 下载安装

下载 [`Mementide-v1.0.apk`](https://github.com/Reverigma/mementide-app/releases/download/v1.0/Mementide-v1.0.apk)，传到手机后允许「安装未知来源应用」即可。

- 最低支持 Android 5.0（API 21）
- 无需任何系统权限，`AndroidManifest.xml` 中未声明网络权限
- 沿用同一签名，可直接覆盖安装升级

---

## 技术架构

```
┌─────────────────────────────────────┐
│  MainActivity (Java)                │
│  ├─ WebView                         │
│  │   └─ file:///android_asset/      │
│  │        index.html                │
│  ├─ JS Bridge                       │
│  │   ├─ 主题色同步系统状态栏         │
│  │   └─ 备份写入「下载」目录         │
│  ├─ 文件选择器（导入备份用）          │
│  └─ 全局 try-catch 崩溃兜底          │
└─────────────────────────────────────┘
```

- **前端**：单个 `index.html`，原生 JS，零依赖、零构建步骤
- **原生壳**：一个 `MainActivity`，约 300 行 Java
- **存储**：`localStorage`，无数据库、无网络请求
- **打包**：手写 `aapt2 → javac → d8 → zipalign → apksigner` 流水线，**不依赖 Gradle**

前端同时是一个合规 PWA（含 `manifest.webmanifest` 与 Service Worker），可直接在浏览器打开或添加到主屏使用。

---

## 项目结构

```
.
├── www/                          # 前端（同时是 APK 的 assets 目录）
│   ├── index.html                #   全部 UI 与业务逻辑
│   ├── manifest.webmanifest      #   PWA 清单
│   ├── sw.js                     #   Service Worker 离线缓存
│   └── icon-{192,512}.png        #   PWA 图标
├── android/
│   ├── AndroidManifest.xml
│   ├── java/com/mementide/app/
│   │   └── MainActivity.java     #   WebView 容器 + JS Bridge
│   └── res/                      #   图标、主题、字符串
├── build/
│   ├── build_apk.sh              # 一键构建脚本
│   └── make_icons.py             # 纯 Python 生成图标（无第三方依赖）
├── index.original.backup.html    # 改造前的原始单页版本，留档
└── Mementide-v1.0.apk            # 已签名安装包（亦见 Releases）
```

---

## 自行构建

**环境要求**

- JDK 17
- Android SDK：`build-tools;34.0.0` + `platforms;android-34`
- Windows + Git Bash（脚本目前针对该环境编写）

**步骤**

```bash
# 按自己的环境设置路径
export JDK_WIN='C:\path\to\jdk-17'
export ANDROID_SDK_WIN='C:\path\to\android-sdk'

# 构建：参数为 versionName 和 versionCode
bash build/build_apk.sh 1.0 5
```

产物输出到项目根目录 `Mementide-v<版本号>.apk`。

**关于签名**：`.keystore` 文件不入库（见 `.gitignore`）。首次构建会自动生成一个新密钥，因此**你构建出的 APK 无法覆盖安装本仓库提供的 APK**，需先卸载。若想保持一致，请妥善保管首次生成的 keystore。

**重新生成图标**：

```bash
python build/make_icons.py .
```

---

## 开发笔记

在 Windows + Git Bash 下手写 Android 打包流水线踩到的坑，都记在 `build/build_apk.sh` 顶部注释里，简述：

| 问题 | 原因 | 解决 |
|---|---|---|
| `aapt2` 报 `failed to open directory` | MSYS2 自动重写路径参数 | `export MSYS_NO_PATHCONV=1`，且一律传反斜杠 Windows 绝对路径 |
| 中文目录构建失败 | `aapt2` 不支持非 ASCII 源路径 | 先同步到 `C:\mtd_build` 再构建 |
| **开屏闪退** | `d8` 只传了单个 `.class`，内部类 `MainActivity$Bridge` 未进 dex，运行时 `NoClassDefFoundError` | 先打成 `classes.jar` 整体喂给 `d8`；构建脚本增加「dex 类数 vs 编译类数」自检 |
| 部分国产 ROM 崩溃 | `WebSettings.setForceDark` 抛异常 | 单独 try-catch 包裹 |
| **装到手机上永远显示 v1.0** | `aapt2 link` 的 `--version-name` / `--version-code` 只在 manifest 缺少该属性时注入，**不会覆盖已有值** | 拷贝源码后用 `sed` 直接改写 manifest 副本再 link |
| `aapt2` 报 `not well-formed (invalid token)` | manifest 注释里写了 `--version-name`，XML 注释中不允许出现连续两个减号 | 注释改写为描述性文字 |
| `aapt2.exe: No such file or directory` | `whoami` 在工作组机器返回 `HOST\user`，拼出 `C:\Users\HOST\user\...` 这种不存在的路径 | 优先读 `USERPROFILE` |
| `cygpath: command not found` | 精简版 Git Bash 不带 `cygpath` | 脚本内置纯 bash 的 `to_mixed` / `to_posix` / `to_win` 兜底 |
| 备份「复制为文本」失效 | APK 内页面跑在 `file://` 下，非安全上下文，`navigator.clipboard` 不可用 | 保留 `document.execCommand('copy')` 兜底，再兜底为填入文本框手动复制 |

---

## License

[MIT](LICENSE)
