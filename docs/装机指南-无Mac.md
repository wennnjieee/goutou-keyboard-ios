# 装机指南（Windows，无 Mac）

> 结论先说：**iOS App 只能在 macOS 上编译**。Windows 上没有 Xcode / 苹果工具链，任何"本地直接编出 .ipa"的路都走不通。
> 这个工程本身就是按"无 Mac"设计的：代码推到 GitHub → Actions 用苹果官方的 macOS 机器编译签名 → 下载 IPA → 侧载到 iPhone。
> 你拿到的是一个**已经通过静态自检、可以直接推上去编译**的完整工程。

---

## 0. 先对齐三件事

| 需要 | 说明 |
|---|---|
| GitHub 账号 | 免费即可。Actions 在**公开仓库完全免费**，私有仓库每月有额度（本项目一次构建约 10-15 分钟，够用） |
| iPhone | 系统 **iOS 16.0+**。「动态整屏识别」这一路要 **iOS 27+**；九键键盘、截图 OCR、军师分析、回复上屏在 16+ 都正常 |
| Apple 账号 | 免费 Apple ID 也能装（**7 天有效**，到期重装）；付费开发者账号（￥688/年）可装 **1 年**，且键盘扩展、App Group 才稳 |

三条可选路线，按"能不能长期用"排序：

- **路线 B（推荐长期用）**：付费/自备 p12 证书 → Actions 出**未签名 IPA** → 你自己用 p12 重签，有效期看你的证书。
- **路线 A（零成本试水）**：免费 Apple ID → Sideloadly 侧载，7 天有效。
- **路线 C（有 Mac 的话最省事）**：Xcode 直接 Run 到手机，免费账号 7 天有效。

---

## ⚡ 最快一条：双击一个脚本，自动出 IPA

工程根目录里有 `一键上云构建.ps1`，它做四件事：建仓库 → 上传全部源码（一个 commit）→ 等 GitHub 的 macOS 机器编译 → 把 Artifact 里的**未签名 IPA** 下到桌面。

1. 打开 https://github.com/settings/tokens/new?scopes=repo,workflow ，Note 随便写，勾 **repo** 和 **workflow**，生成后复制那串 `ghp_...`（只显示一次）。
2. 在工程文件夹里按住 **Shift + 右键** → 「在此处打开 PowerShell 窗口」，执行：
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\一键上云构建.ps1
   ```
3. 粘贴 token 回车，等 10-20 分钟。结束时会打印 IPA 的完整路径（`桌面\goutou-ipa\`）。
4. 拿这个 IPA 用你的 p12 重签即可。
   - 只做本地预检、不联网：加 `-DryRun`
   - 想建成私有仓库：加 `-Private`（私有仓库 Actions 每月有免费额度）

> 也可以完全不跑脚本：把整个文件夹用 GitHub Desktop 推到你自己的仓库，效果一样，Actions 会自动跑。

---


## 1. 把代码推上 GitHub（三条路线都要做）

1. 打开 https://github.com/new ，仓库名填 `goutou-keyboard-ios`，**Public**，不要勾任何初始化文件，创建。
2. 上传代码：用 **GitHub Desktop**（https://desktop.github.com ）最省事 —— Clone 刚建的空仓库到本地 → 把本工程里所有文件（含 `.github` 隐藏目录）拷进去 → Commit → Push。
   > 网页版拖拽上传有时会漏掉 `.github/` 和 `tools/` 子目录，漏了流水线就跑不起来，建议用 GitHub Desktop。
3. 推上去后点仓库顶部 **Actions** 标签，会自动跑一次 `Build iOS Keyboard`。

流水线在 `xcode-27` 镜像上跑（GitHub 官方 macOS 27 + Xcode 27，2026-10 已正式可用），先跑十几组纯 Swift 冒烟测试，再编 Debug / 跑模拟器单测 / 打 Release 包，最后产出**未签名 IPA**。约 10-15 分钟。

---

## 2. 路线 A：免费 Apple ID 侧载（7 天）

1. Actions 跑完后进那次运行，页面底部 **Artifacts** → 下载 `GoutouInput-unsigned`，解压得到 `GoutouInput-Final-unsigned-<build>.ipa`。
2. Windows 装 **iTunes**（Microsoft Store 版即可，Sideloadly 靠它连手机）和 **Sideloadly**（https://sideloadly.io ）。
3. 数据线连 iPhone，Sideloadly 里选这个 ipa，Apple 账号填你的 Apple ID，Start。
4. 装完：设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID。
5. 桌面出现「狗头军师」App 就算成功。

⚠️ 免费账号的三个现实问题（不是这个工程的问题，是所有侧载都这样）：
- **7 天到期**，App 打不开，要重复第 3 步重签一次。
- **App Group 用不了**。键盘读不到主 App 存的聊天（「读取识别聊天」会提示"共享容器不可用"），但**键盘里的军师面板本身能正常用**（配置走剪贴板）。
- **iOS 27 + 免费账号的侧载目前大面积报错**（`ApplicationVerificationFailed` / `provisioning profile is banned`），以及 Sideloadly 重签**键盘扩展**有稳定复现的 `CODESIGNING / Invalid Page` 崩溃报告（主 App 正常、键盘一选就跳回系统键盘）。撞上这两条，路线 A 基本没救，直接看路线 B。

---

## 3. 路线 B：付费开发者账号（推荐，装一次用一年）

前提：苹果开发者账号（个人 ￥688/年），iPhone 的 **UDID** 已加进账号。

### 3.1 改三处标识（必须改，别用示例值）

| 位置 | 改什么 |
|---|---|
| `project.yml` 第 37 行 | `com.example.goutouinput` → 你的 App ID（如 `com.你的名字.goutou`） |
| `project.yml` 第 63 行 | Widget 扩展 ID |
| `project.yml` 第 100 行 | 键盘扩展 ID（**必须以 App ID 开头**） |
| `.github/workflows/build-ios.yml` 第 29-30 行 | `BUNDLE_ID` / `EXTENSION_BUNDLE_ID` 同步改成上面两个 |
| `App/GoutouInput.entitlements`、`Keyboard/GoutouKeyboard.entitlements` | `group.GDK748UUB7.pOgtZpt` → 你在开发者后台建的 App Group（如 `group.com.你的名字.goutou`） |
| `Shared/SharedConstants.swift` 第 6 行 | 同上，改成同一个 App Group |

> 那两个 entitlements 和 `SharedConstants.swift` 里的 group 是**原作者的签名服务商提供的**，不属于你，不改就装不上你的签名（或者装上了键鼠两端也不通）。

### 3.2 开发者后台准备

1. **Identifiers** 里建两个 App ID：主 App + 键盘扩展（扩展 ID 必须填主 App ID 加 `.keyboard`）。两个都要勾 **App Groups** 并绑定同一个 group。
2. **Devices** 里加你的 iPhone UDID（爱思助手 / Apple Configurator 都能读）。
3. **Profiles** 里各建一份 **Ad Hoc** 描述文件（主 App 一份、键盘扩展一份），下载成 `.mobileprovision`。
4. 证书：Apple Distribution 证书 p12（`openssl pkcs12 -export -legacy` 打的）+ Apple Development 证书 p12。
5. **App Store Connect → 用户和访问 → 集成 → App Store Connect API** 建一个 Key，下 `.p8`。

### 3.3 配 Secrets

仓库 Settings → Secrets and variables → Actions → New repository secret，逐个填：

| Secret | 内容 |
|---|---|
| `APPLE_CERTIFICATE_BASE64` | Distribution p12 的 base64 |
| `APPLE_CERTIFICATE_PASSWORD` | 上面 p12 的密码 |
| `APPLE_DEV_CERTIFICATE_BASE64` | Development p12 的 base64 |
| `APPLE_DEV_CERTIFICATE_PASSWORD` | 上面 p12 的密码 |
| `APPLE_TEAM_ID` | 10 位 Team ID |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` | ASC API Key 的 ID 和 Issuer ID |
| `ASC_API_KEY_BASE64` | `.p8` 文件内容的 base64 |
| `APPLE_ADHOC_PROFILE_BASE64` | **主 App** 的 Ad Hoc 描述文件 base64 |
| `APPLE_ADHOC_EXT_PROFILE_BASE64` | **键盘扩展** 的 Ad Hoc 描述文件 base64 |

Windows 上打 base64：`certutil -encode cert.p12 cert.b64`，再把首尾 `-----BEGIN/END-----` 两行删掉。
（可选：`OTA_SSH_HOST` / `OTA_SSH_USER` / `OTA_SSH_PASSWORD` / 改 workflow 里 `OTA_URL_BASE`、`OTA_DIR`，就能把 IPA 推到自己的服务器出免电脑的 OTA 装机页。）

### 3.4 打 tag 出签名包

```bash
git tag adhoc-v1.0.0
git push origin adhoc-v1.0.0
```

约 12 分钟，Artifacts 里出现 `GoutouInput-adhoc-signed`（ipa + manifest.plist + install.html）。装了 OTA 服务器的，Safari 打开发给你的 `install.html` → 点安装 → 装完去 设置 → 通用 → VPN 与设备管理 → 信任证书。

---

## 3.5 用你自己的 p12 重签（拿到未签名 IPA 之后）

1. 工具：**Sideloadly**（Windows，需装 iTunes）／**爱思助手**／**轻松签(Esign)**（手机上签）。
2. **三个 bundle 必须一起签、用同一张证书同一个 Team**：
   `GoutouInput.app` + `PlugIns/GoutouKeyboard.appex` + `PlugIns/GoutouCaptureWidget.appex`。
   只签主 App 不签扩展 → 装上了键盘也调不出来。
3. **Bundle ID 要落在你证书允许的范围里**：证书是 `com.xxx.*` 通配就随便；不是通配就必须把 `project.yml` 里的 ID 改成证书对应的那个（改完重新构建）。
4. **App Group**：工程里写死的是 `group.GDK748UUB7.pOgtZpt`（作者的签名服务商提供的，不属于你）。
   你的 p12 里没有这个组，结果就是「共享容器不可用」——**主 App 的截图/动态识别结果送不进键盘**，但键盘里的九键、军师面板、AI 分析、回复上屏全部照常。
   要打通这条通道，就把这个组名改成**你自己证书里的 App Group**，一共 4 处：
   `App/GoutouInput.entitlements`、`Keyboard/GoutouKeyboard.entitlements`、`Shared/SharedConstants.swift` 第 6 行，并在开发者后台把两个 App ID 都绑上这个组。
5. 免费个人证书签的**键盘扩展**在 iOS 26/27 上有稳定复现的 `CODESIGNING / Invalid Page` 崩溃（主 App 正常、键盘一跳回系统键盘）；付费/企业证书没这个问题。

---

## 4. 装上之后（三条路线都一样）


1. **设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 第三方键盘 → 狗头军师**
2. 点进「狗头军师」把 **允许完全访问** 打开（键盘要读剪贴板、要联网调 AI，不开这个所有军师功能都不可用）
3. 任意输入框长按 🌐 切到狗头军师。默认中文九键，顶部 🐶 是军师入口，底栏「中英」切英文 26 键
4. 回主 App：填 **Base URL / Model / API Key**（任何 OpenAI 兼容接口，比如 `https://api.deepseek.com/v1` + `deepseek-chat`）→ 点「复制配置到剪贴板」
5. 切到键盘 → 🐶 → ⚙ 设置 → 「⬇️ 从剪贴板导入配置」
6. 正式用：复制对方的话 → 👤对方 → ⟳ 分析 → 点一条话术（**只插入输入框，不会自动发送**）

---

## 5. 已知坑

- **密码框**系统强制切回自带键盘，这是 iOS 行为，不是 bug。
- **动态整屏识别**要 iOS 27，且必须你自己在系统共享界面选"整屏"；它不是偷偷读微信。
- **聊天上下文会明文落盘**在键盘沙盒里（作者自己在 README 里写明了），介意就别存敏感内容。
- 免费账号下 App Group 不可用 → 主 App「保存给狗头军师」与键盘「读取识别聊天」之间的通道失效，其余功能照常。
- `tools/fetch-pinyin-data.py` 只在需要重新生成词库时用，日常构建不碰（两份 TSV 已随仓库提供）。
