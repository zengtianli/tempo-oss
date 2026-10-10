# Tempo · 倍速

[中文](README.md) | **English**

Set one playback speed for videos and audio in Safari, adjust it with the keyboard, and remember a speed or disable the extension per site. [Global Speed](https://github.com/polywock/globalSpeed) inspired the features; Tempo provides its own Safari implementation.

## Install and enable

Requires macOS 14 or later. Download the Developer ID signed, notarized and stapled ZIP from [Releases](https://github.com/zengtianli/tempo-oss/releases/latest), unzip it, and drag `Tempo.app` into Applications. Releases include a SHA256 checksum file.

1. Open Tempo and click its button to open Safari extension settings, or go to Safari → Settings → Extensions.
2. Enable **Tempo · 倍速**.
3. Choose which websites it may access. For global speed control, choose Always Allow on Every Website. You must confirm enablement and website permissions yourself.
4. Reload pages opened before enabling it, then click Tempo in Safari's toolbar to set the speed.

Export settings from the panel before upgrading, close the Tempo host window, and replace the app. Settings remain in Safari; packages contain no author's configuration. There is no automatic updater; download new packages from Releases.

## Features and shortcuts

- Global speed across tabs and embedded players, with an attempt to maintain it when pages change it.
- Separate speed or disabled state per site, including subdomains.
- Speed presets, switches, key bindings, step size, seek length and settings import/export.
- An optional upper-left speed indicator. Shortcuts act only when the page has media and you are not typing.

| Default key | Action |
|---|---|
| `D` / `A` | Faster / slower |
| `S` | Switch between normal and previous speed |
| `X` / `Z` | Forward / rewind |
| `⇧X` / `⇧Z` | Next / previous frame |
| `⇧W` / `W` | Remember / return to position |

Play/pause, mute, picture in picture and the Tempo switch have no default key; bind them in the panel.

## Command line

Use `/Applications/Tempo.app/Contents/MacOS/Tempo` directly or create a symlink:

```sh
mkdir -p ~/.local/bin
ln -s /Applications/Tempo.app/Contents/MacOS/Tempo ~/.local/bin/tempo
```

Add `~/.local/bin` to PATH. Inspect any existing command before replacing it. Commands with arguments do not open a window and use the same settings as the panel:

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

Safari creates the store after the first settings write; change an option or import in the panel first. The CLI reports inaccessible storage rather than creating it. If macOS denies your terminal access to Safari data, grant permission yourself in System Settings. Do not commit real settings to a public repository.

The optional command channel is off by default. Enable it with `tempo set remote on` or the panel checkbox 允许 tempo 命令控制当前页的视频, then bring a media page forward or reload it:

```sh
tempo page --json
tempo do mute --json
tempo do forward --json
```

Actions share the shortcut implementation. With the channel enabled and a media page connected, settings commands can notify pages to reload immediately; otherwise pages reload settings when brought forward or refreshed. Commands do not launch a closed Safari. Playback or picture in picture may require a real user gesture; refusals produce errors. End-to-end channel behavior in real Safari pages still needs further verification.

Every command supports `--json`; see `tempo --help` for all options. Exit codes: `0` success, `1` failed action or disabled extension, `2` usage error or no Safari status answer, `3` status found an unnotarized build, `4` inaccessible storage, `5` unreachable page or channel.

## Build from source

Install Xcode and its command-line tools, XcodeGen, FFmpeg, Python 3 and Pillow. Source includes no certificates, keys or notarization credentials. Your own Apple Developer ID and notarization access are required for a distribution build.

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

`NOTARY_PROFILE` is your own Keychain profile saved with `xcrun notarytool store-credentials`; the script also accepts your own API-key environment variables as documented in its comments. Author credentials are not provided. An unnotarized build is not a distribution package; do not substitute weaker Safari security settings for notarization.

`build.sh` tests first, builds host and extension separately, embeds the extension afterwards, and signs the host again. This avoids registering a second Safari extension from the build directory. Build and install attempt to back up settings in `build/settings/`. Tests use offscreen WKWebView and temporary stores without driving Safari or touching its settings; they do not verify real playback.

## Structure and public snapshot

- `Extension/Resources/engine.js`: page-world media engine with an isolated-world fallback.
- `content.js`: settings, shortcuts and indicators; `shared.js`: rules shared with panel and CLI.
- `background.js`: frame forwarding, toolbar badge and optional command channel.
- `App/`, `Extension/*.swift`, `Shared/`: host app, CLI and local message relay.
- `Tests/`: page behavior, fallback and CLI tests.

This is a one-way allowlisted snapshot of the development repository, excluding private history, handoffs, personal settings and internal records. Development continues in the original repository. `python3 scripts/export-public.py EMPTY_DIRECTORY --ref COMMIT` exports a committed revision without uncommitted changes. The signing team is blank; set `DEVELOPMENT_TEAM` at build time. Python is resolved through PATH.

## Privacy, limitations and troubleshooting

No network calls or data collection. Website access locates and adjusts media; `storage` holds local settings and `nativeMessaging` communicates only with the local app extension. The optional channel reads the current tab's hostname and media state; requests and replies remain in its sandbox and are removed after reading. Other local programs with access to that directory can send equivalent requests.

- No iCloud settings sync; use panel export/import between Macs.
- No per-tab pinned speed, audio effects or video filters; macOS Safari only.
- Missing extension: check notarization and that the app is in Applications.
- Inactive shortcuts: check enablement and website access, reload, and leave text fields.
- Reset settings: paste your own backup under 快捷键与设置 → 导入配置 in the panel. Restore there first if Safari has not recreated its store, then use the CLI.
- Audio at high speeds or pages repeatedly resetting speed may be limited by Safari or the website.

## License

[MIT](LICENSE). See [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) for feature inspiration and build tools.
