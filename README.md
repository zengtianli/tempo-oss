# Tempo · 倍速

**中文** | [English](README_EN.md)

[下载正式 ZIP](https://github.com/zengtianli/tempo-oss/releases/download/v0.1.4/Tempo-0.1.4-mac.zip) · [MIT 公开源码](https://github.com/zengtianli/tempo-oss)。

给 Safari 网页的视频和音频设定统一播放速度，随时用键盘调整，也能按网站记住速度或停用规则。功能灵感来自 [Global Speed](https://github.com/polywock/globalSpeed)，Safari 实现由 Tempo 自己提供。

## 安装与启用

需要 macOS 14 或更新版本。到 [Releases](https://github.com/zengtianli/tempo-oss/releases/latest) 下载已用 Developer ID 签名、公证并装订的 ZIP，解压后把 `Tempo.app` 拖进「应用程序」。发行页提供 SHA256 校验文件。

1. 打开 Tempo，点「打开 Safari 扩展设置」；也可以直接进 Safari → 设置 → 扩展。
2. 勾选 **Tempo · 倍速**。
3. 在网站访问权限里选择要允许的网站；需要全局倍速时，选择「在所有网站上始终允许」。启用与网站授权需要你亲自确认。
4. 刷新启用前已经打开的网页，点 Safari 工具栏上的 Tempo 图标设置速度。

升级前从面板导出配置留底；退出 Tempo 容器窗口再替换 App。设置保存在 Safari 中，安装包不带作者的设置。容器 App 的「设置与更新…」可检查既有公开 Release，并选择自动检查的间隔；默认关闭自动检查、下载与安装。

## 功能与快捷键

- 所有标签页和内嵌播放器共用全局速度；网页把速度改回去时，Tempo 会尝试保持设定值。
- 本站单独记速度或本站停用；规则包含子域名。
- 面板提供速度预设、开关、改键、步长、快进秒数和配置导入导出。
- 页面左上角显示速度提示，可关闭。按键仅在页面有媒体且没有输入文字时生效。

| 默认按键 | 动作 |
|---|---|
| `D` / `A` | 加速 / 减速 |
| `S` | 在正常速度与上次速度间切换 |
| `X` / `Z` | 快进 / 快退 |
| `⇧X` / `⇧Z` | 下一帧 / 上一帧 |
| `⇧W` / `W` | 记下当前位置 / 回到记下的位置 |

播放暂停、静音、画中画和开关 Tempo 默认没有绑定按键，可在面板里设置。

## 命令行

拖入 App 后可直接用 `/Applications/Tempo.app/Contents/MacOS/Tempo`，或创建软链：

```sh
mkdir -p ~/.local/bin
ln -s /Applications/Tempo.app/Contents/MacOS/Tempo ~/.local/bin/tempo
```

把 `~/.local/bin` 加入 PATH；已有同名文件时先检查，不要覆盖。命令带参数时不开窗口，和面板读写同一份设置：

```sh
tempo status --json
tempo show --site example.com --json
tempo speed 1.5
tempo site example.com rule 2
tempo set step 0.25
tempo bind pause Shift+KeyP
tempo export > tempo.json
tempo import tempo.json
tempo --help
```

Safari 首次写入设置才建立扩展存储；先在面板里改一项或导入配置。CLI 读不到存储时会退出并说明；若终端被 macOS 拒绝访问 Safari 数据，需要你在系统设置中自行授权。不要把真实配置文件提交到公开仓库。

可选命令通道默认关闭。用 `tempo set remote on` 或面板里的「允许 tempo 命令控制当前页的视频」打开，再切回或刷新一个带媒体的页面：

```sh
tempo page --json
tempo do mute --json
tempo do forward --json
```

动作与快捷键共用实现。通道打开且有媒体页面连接时，写命令可通知页面即时重读；否则页面切回或刷新时重读。Safari 没运行时命令不会启动它。播放或画中画可能需要真人操作，被拒绝时返回错误。通道在真实 Safari 页面中的完整行为仍待进一步验证。

每条命令支持 `--json`，完整参数见 `tempo --help`。退出码：`0` 成功、`1` 操作失败或扩展未启用、`2` 用法错误或 Safari 没回答状态查询、`3` 状态查询发现未公证构建、`4` 存储不可访问、`5` 页面或命令通道不可达。

## 从源码构建

安装 Xcode（含命令行工具）、XcodeGen、FFmpeg、Python 3 和 Pillow。源码不带签名证书、密钥或公证凭据；正式安装包需要你自己的 Apple Developer ID 和公证权限。

```sh
git clone https://github.com/zengtianli/tempo-oss.git
cd tempo-oss
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install Pillow
bash build.sh --test-only
DEVELOPMENT_TEAM=YOUR_TEAM_ID PYTHON=python3 bash build.sh
NOTARY_PROFILE=your-notary-profile bash scripts/notarize.sh
bash scripts/install.sh
```

`NOTARY_PROFILE` 是你自己用 `xcrun notarytool store-credentials` 保存的钥匙串配置；脚本也支持自己的 API 密钥环境变量，见注释。不提供作者凭据。未公证构建不能作为正式发行包，不要通过降低 Safari 安全设置代替公证。

`build.sh` 先测试，再分别构建 App 与扩展，最后嵌入扩展并重新签名，以免构建目录被登记为另一份 Safari 扩展。构建和安装会尝试备份设置到 `build/settings/`。测试使用离屏 WKWebView 和临时存储，不驱动真实 Safari、不碰它的配置，不能代替真实视频播放验证。

## 结构与公开快照

- `Extension/Resources/engine.js`：网页世界媒体引擎，隔离世界有回退实现。
- `content.js`：设置、按键、提示；`shared.js`：面板与命令共用的规则。
- `background.js`：跨框架转发、角标和可选命令通道。
- `App/`、`Extension/*.swift`、`Shared/`：容器 App、CLI、本机消息中继。
- `Tests/`：网页行为、回退与命令行测试。

本公开仓是开发仓的单向白名单快照，不含私有历史、交接、个人配置和内部台账。日常开发在原开发仓完成；`python3 scripts/export-public.py 空目录 --ref 提交号` 可从指定已提交版本重出快照，不携带未提交改动。签名团队留空，构建时通过 `DEVELOPMENT_TEAM` 设置；Python 默认走 PATH。

## 隐私、限制与排障

不收集使用数据。网页扩展自身不联网；容器 App 检查更新时匿名读取 GitHub 公开 Release 的既有 release-manifest.json，可选 iCloud 配置同步由系统 Apple ID 与 iCloud Drive 完成。网站权限用于找到媒体并调整播放；`storage` 存本机设置，`nativeMessaging` 只用于本机容器扩展通信。可选通道会读当前标签页主机名与媒体状态，请求和回答留在扩展沙盒里，读完删除；能访问该目录的本机程序也能发同类请求。

- 「设置与更新…」提供可选 iCloud 同步（默认关闭），同步速度、网站规则、媒体按键与本 App 刷新键；命令通道开关、Safari 网站授权不迁移。同步在容器 App 打开期间通过文件事件跟随，或用 `tempo config sync on --yes` 显式同步；无常驻同步后台。换机也可导出 / 导入。
- CLI：`tempo config status --json`、`tempo config export -o 文件`、`tempo config import 文件 --yes`、`tempo config sync on|off --yes`、`tempo update check --json`、`tempo update options --json`。原生窗口 ⌘R 刷新，可关闭/改键，保留系统编辑组合。
- 没有固定到单个标签页的速度、音效或画面滤镜；只提供 macOS Safari 版。
- 扩展找不到：检查安装包是否已公证、App 是否在「应用程序」。
- 按键无反应：检查启用状态与网站权限，刷新页面，确认光标没在输入框。
- 设置恢复默认：在面板「快捷键与设置 → 导入配置」粘贴自己的备份；存储未重建时先通过面板恢复，再用 CLI。
- 某些源高倍速无声音，或网页持续抢回速度，可能受 Safari 或网站限制。

## 许可证

[MIT](LICENSE)。功能参考和第三方工具说明见 [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES)。
