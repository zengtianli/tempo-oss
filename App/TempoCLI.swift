#if !APP_STORE
import Foundation
import JavaScriptCore
import SQLite3

/// The settings commands. They read and write the store the extension itself uses (Safari keeps an
/// extension's `storage.local` in a small SQLite file) and work out every change with the extension's own
/// rules: `shared.js` from the bundled extension runs here in JavaScriptCore, so the panel and the command
/// cannot disagree. Nothing opens on screen and Safari is not asked for anything.
/// `page` and `do` go to the page in Safari's current tab instead; how they get there is in TempoRemote.swift.
struct CLIFailure: Error {
    let exit: Int32
    let code: String
    let message: String
}

enum CLI {
    static let usage = """
        Tempo · 倍速 的命令行：读写 Safari 里 Tempo 的设置（与工具栏面板是同一份），并对当前标签页的视频执行
        快捷键能做的动作，不打开窗口

        读命令（不写任何文件或状态）：
          tempo status [--json]                 版本、扩展是否已在 Safari 启用（容器 App 窗口里的状态行）
          tempo show [--site 网站] [--json]      当前全部设置；带 --site 时另报这个网站实际用的速度、是否停用
                                                （面板读数与工具栏角标显示的就是这个速度；1× 或停用时角标为空）
          tempo page [--json]                   Safari 当前标签页是哪个网站、它实际用的速度（面板网站行与角标
                                                对着的那个页面），以及页面里视频或音频此刻的状态
          tempo keys [--json]                   每个动作当前绑的键（面板“快捷键与设置”里的列表）
          tempo export [--json]                 导出配置，文本与面板“导出配置”相同

        写命令（写的是扩展自己的存储，规则用扩展的 shared.js）：
          tempo speed <0.1–16|up|down|toggle> [--site 网站] [--json]
                                                设速度 / 按步长加减 / 在 1× 与上次速度之间切换（面板的预设、＋－、读数）
          tempo on | off [--json]               开 / 关 Tempo（面板右上角开关）
          tempo site <网站> rule [速度] | follow | disable | enable [--json]
                                                本站单独记速度（rule）/ 跟随全局（follow）；本站停用（disable）/ 恢复（enable）
          tempo set step <0.01–1> | seek <1–600> | indicator <on|off> | remote <on|off> [--json]
                                                每次加减的步长、快进快退秒数、页面左上角提示、命令通道（见下）
          tempo bind <动作> <组合|none> [--json] 改键；动作名见 tempo keys，组合写法同存储：KeyD、Shift+KeyZ、
                                                Ctrl+Alt+Shift+Meta+BracketLeft，也接受单个字母或数字
          tempo import <文件|-> [--json]         导入配置（面板“导入配置”）；- 表示从标准输入读
          tempo defaults --yes [--json]         恢复默认：速度、网站规则和快捷键都回到初始值；不带 --yes 不执行
          tempo do <动作> [--json]               对当前标签页执行一个动作，和按它的快捷键走同一段代码：
                                                rewind / forward 快退 / 快进，framePrev / frameNext 上一帧 / 下一帧，
                                                mark / jump 记下 / 回到位置，pause 播放或暂停，mute 静音，pip 画中画，
                                                slower / faster / reset 减速 / 加速 / 1× 与上次速度，toggle 开关 Tempo

        通用参数：--json；--profile <Safari 个人资料目录名>（默认 Default）。参数写在命令之后。
        不带任何参数启动时打开 Tempo 的窗口；带了参数就不开窗口：第一个参数是不认识的选项（如 tempo --json status）
          按用法错误退出 2，status 后面多出的参数同样退出 2。
        --json 输出：成功 {"ok": true, …}；失败 {"ok": false, "error": {"code", "message"}}，退出码非零。
          show    {"ok","version","settings":{enabled,speed,last,step,seek,indicator,remote,rules,off,keys},
                   "site":{host,speed,off,site_off,rule}|null,"store"}
          page    {"ok","page":{host,speed,off,site_off,rule,has_media},
                   "media":{kind,paused,muted,time,duration,rate,pip,mark}|null}；页面里没有视频或音频时 media 为 null
          do      {"ok","action","page":{…},"result":{动作的直接结果}|null,"media":{动作之后的状态}|null}
          写命令   {"ok","changed":{本次写入的键},"settings":{…},"site":…|null,"live":true|false}；bind 另有 "freed"
          keys    {"ok","keys":[{action,name,combo,label}]}        export  {"ok","config":{…}}
          status  保持原形状 {"version","enabled"}；未公证时另有 "notarized":false，Safari 没回答时另有 "error" 字符串；
                  参数写错时与其他命令一样输出 {"ok": false, "error": {…}}
        退出码：0 成功；1 操作失败（status：已安装未启用；do：页面收到了但动作没有发生）；
                2 用法错误（status：也表示 Safari 没有回答）；3 仅 status：本构建未公证，Safari 不会列出它；
                4 读写不到 Safari 里的设置存储（Safari 还没建它、运行本命令的终端没有“完全磁盘访问权限”、或格式不认识）。
                  Safari 在扩展第一次写入设置时才建这个存储：在 Safari 的 Tempo 面板里改一项或导入一次配置之后再用命令。
                5 仅 page、do：够不着当前标签页的页面，error.code 说明是哪一种：safari_not_running（Safari 没开，
                  本命令不启动它）、channel_off（命令通道没开）、extension_disabled（扩展没启用）、channel_asleep
                  （没有在听命令的页面）、no_page（当前标签页不是普通网页）、no_tab、not_ready、no_answer、
                  mailbox_unwritable。
                do 退出 1 时的 error.code：no_media（当前标签页没有视频或音频）、site_off、tempo_off、
                  not_allowed（网页或 Safari 不接受没有真人按键的播放或画中画）、not_video、unsupported、no_mark、
                  failed。
        命令通道（tempo set remote on，面板“快捷键与设置”里同一个开关，默认关）：打开后，有视频或音频的页面
          会让扩展的后台页保持待命，page 与 do 才够得着它，写命令也会通知所有打开着的页面立即生效
          （"live": true）。只要没有这样的页面，或开关关着，就没有任何东西待命。开关用命令打开后，已打开的
          页面要切到前台或刷新一次才接上。请求只在本机传递：命令在扩展自己的目录里留一个文件，不联网，
          不启动也不切换 Safari，不发按键。
        生效时机（"live": false）：写入后新打开或刷新的页面立即按新设置；已打开的页面在它的标签页或窗口
          再次被切到时读到。
        仅在窗口中：在 Safari 设置里启用扩展、授予网站权限（系统授权，要本人点）；打开 Safari 扩展设置；
          页面左上角的提示。
        """

    static let commands: Set<String> = ["show", "keys", "export", "speed", "on", "off", "site", "set", "bind", "import", "defaults", "page", "do"]
    static let reads: Set<String> = ["show", "keys", "export"]
    /// Answered by the page in Safari's current tab, not from the store.
    static let remotes: Set<String> = ["page", "do"]
    static let options: Set<String> = ["--json", "--site", "--profile", "--yes"]

    /// Reports a failure the same way everywhere: the reason on stderr, the error object on stdout when
    /// --json was given, and the failure's exit code.
    static func fail(_ failure: CLIFailure, json: Bool) -> Never {
        if json {
            let body: [String: Any] = ["ok": false, "error": ["code": failure.code, "message": failure.message]]
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
            print(String(decoding: data, as: UTF8.self))
        }
        let hint = failure.exit == 2 ? "（用法见 tempo --help）" : ""
        FileHandle.standardError.write("tempo: \(failure.message)\(hint)\n".data(using: .utf8)!)
        exit(failure.exit)
    }

    static func run(_ argv: [String]) -> Never {
        let json = argv.contains("--json")
        do {
            let reply = try execute(argv)
            print(json ? reply.out : reply.text)
            exit(0)
        } catch let failure as CLIFailure {
            fail(failure, json: json)
        } catch {
            FileHandle.standardError.write("tempo: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    static func execute(_ argv: [String]) throws -> Engine.Reply {
        let command = argv[0]
        var positionals: [String] = []
        var site: String?
        var profile = "Default"
        var yes = false
        var index = 1
        while index < argv.count {
            let word = argv[index]
            switch word {
            case "--json": break
            case "--yes": yes = true
            case "--site", "--profile":
                guard index + 1 < argv.count else {
                    throw CLIFailure(exit: 2, code: "missing_value", message: "\(word) 后面要跟一个值")
                }
                index += 1
                if word == "--site" { site = argv[index] } else { profile = argv[index] }
            default:
                if word.hasPrefix("--") {
                    throw CLIFailure(exit: 2, code: "unknown_option", message: "不认识的参数 \(word)")
                }
                positionals.append(word)
            }
            index += 1
        }
        guard commands.contains(command) else {
            throw CLIFailure(exit: 2, code: "unknown_command", message: "没有“\(command)”这个命令")
        }

        let engine = try Engine()
        var input: [String: Any] = [
            "command": command, "args": positionals, "yes": yes, "rows": [String: String](), "dry": true,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
        ]
        if let site { input["site"] = site }
        // First pass against an empty store: a wrong argument is reported as such before anything is opened.
        _ = try engine.run(input)

        if remotes.contains(command) {
            input["dry"] = false
            input["remote"] = try Remote.send(action: command == "page" ? "page" : positionals[0], profile: profile)
            return try engine.run(input)
        }

        if command == "import" {
            let source = positionals[0]
            let data = source == "-" ? FileHandle.standardInput.readDataToEndOfFile() : FileManager.default.contents(atPath: source)
            guard let data, let text = String(data: data, encoding: .utf8) else {
                throw CLIFailure(exit: 1, code: "unreadable_file", message: "读不到配置文件 \(source)")
            }
            input["text"] = text
        }

        let store = try Store(path: try Store.locate(profile: profile), writable: !reads.contains(command))
        defer { store.close() }
        input["dry"] = false
        input["store"] = store.path
        if reads.contains(command) {
            input["rows"] = try store.rows()
            return try engine.run(input)
        }
        try store.begin()
        do {
            input["rows"] = try store.rows()
            let reply = try engine.run(input)
            try store.apply(writes: reply.writes, clear: reply.clear)
            try store.commit()
            // Written. Open pages are told to read it now when something on Safari's side is listening.
            return Remote.nudge(profile: profile) ? reply.live : reply
        } catch {
            store.rollback()
            throw error
        }
    }
}

/// The extension's rules (`shared.js`) plus the few lines that map a command onto them.
final class Engine {
    struct Reply {
        let out: String
        let text: String
        let writes: [String: String]
        let clear: Bool
        let outLive: String
        let textLive: String

        /// The same reply for a write that open pages were told about ("live": true).
        var live: Reply { Reply(out: outLive, text: textLive, writes: writes, clear: clear, outLive: outLive, textLive: textLive) }
    }

    private let function: JSValue

    init() throws {
        let folder = ProcessInfo.processInfo.environment["TEMPO_RESOURCES"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.builtInPlugInsURL?.appendingPathComponent("TempoExtension.appex/Contents/Resources")
        guard let folder, let context = JSContext(),
              let rules = try? String(contentsOf: folder.appendingPathComponent("shared.js"), encoding: .utf8) else {
            throw CLIFailure(exit: 1, code: "engine_missing", message: "找不到扩展的 shared.js；本命令要从 Tempo.app 里运行")
        }
        context.evaluateScript(rules)
        guard context.exception == nil, let function = context.evaluateScript("(" + Engine.glue + ")"),
              context.exception == nil, !function.isUndefined else {
            throw CLIFailure(exit: 1, code: "engine_failed", message: "扩展的规则没有加载成功：\(context.exception?.toString() ?? "unknown")")
        }
        self.function = function
    }

    func run(_ input: [String: Any]) throws -> Reply {
        let data = try JSONSerialization.data(withJSONObject: input)
        let context = function.context!
        context.exception = nil
        let result = function.call(withArguments: [String(decoding: data, as: UTF8.self)])
        guard context.exception == nil, let text = result?.toString(),
              let reply = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CLIFailure(exit: 1, code: "engine_failed", message: "规则执行出错：\(context.exception?.toString() ?? "no result")")
        }
        if let fail = reply["fail"] as? [String: Any] {
            throw CLIFailure(exit: Int32(fail["exit"] as? Int ?? 1), code: fail["code"] as? String ?? "failed",
                             message: fail["message"] as? String ?? "")
        }
        let out = reply["out"] as? String ?? "{}"
        let summary = reply["text"] as? String ?? ""
        return Reply(out: out, text: summary, writes: reply["writes"] as? [String: String] ?? [:], clear: reply["clear"] as? Bool ?? false,
                     outLive: reply["outLive"] as? String ?? out, textLive: reply["textLive"] as? String ?? summary)
    }

    /// Takes the command and the stored rows (key -> JSON text, as Safari keeps them); returns what to print
    /// and what to store. Numbers stay inside JavaScript from the stored text to the printed text, so they
    /// are written exactly as the extension would write them.
    static let glue = #"""
        function (json) {
          'use strict';
          const input = JSON.parse(json);
          const T = globalThis.Tempo;
          function Fail(exit, code, message) { this.exit = exit; this.code = code; this.message = message; }
          const usage = (code, message) => { throw new Fail(2, code, message); };
          const failed = (code, message) => { throw new Fail(1, code, message); };

          const number = (text, what, min, max, whole) => {
            if (!(whole ? /^\d+$/ : /^\d+(\.\d+)?$/).test(text)) usage('bad_value', `${what}要是${whole ? '整数' : '数字'}，收到“${text}”`);
            const v = Number(text);
            if (v < min || v > max) usage('out_of_range', `${what}的范围是 ${min}–${max}，收到 ${text}`);
            return v;
          };
          const hostOf = (text) => {
            const bare = String(text).trim().replace(/^[a-z][a-z0-9+.-]*:\/\//i, '').replace(/[\/?#].*$/, '').replace(/^.*@/, '').replace(/:\d+$/, '');
            const h = T.hostKey(bare);
            if (!/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/.test(h)) usage('bad_site', `网站要写主机名，例如 bilibili.com，收到“${text}”`);
            return h;
          };
          const onOff = (text, what) => {
            if (text !== 'on' && text !== 'off') usage('bad_value', `${what}只能是 on 或 off，收到“${text}”`);
            return text === 'on';
          };
          const MODS = { ctrl: 'Ctrl', control: 'Ctrl', alt: 'Alt', option: 'Alt', opt: 'Alt', shift: 'Shift', meta: 'Meta', cmd: 'Meta', command: 'Meta' };
          const comboOf = (text) => {
            if (text === 'none' || text === '') return '';
            const parts = text.split('+');
            let code = parts.pop();
            const mods = parts.map((p) => MODS[p.toLowerCase()] || usage('bad_combo', `修饰键只能是 Ctrl、Alt、Shift、Meta，收到“${p}”`));
            if (/^[a-z]$/i.test(code)) code = 'Key' + code.toUpperCase();
            else if (/^\d$/.test(code)) code = 'Digit' + code;
            if (!/^[A-Z][A-Za-z0-9]*$/.test(code) || /^(Shift|Control|Alt|Meta|OS)(Left|Right)?$/.test(code)) {
              usage('bad_combo', `按键要写键位名（KeyD、Digit1、ArrowLeft、BracketLeft…）或单个字母、数字，收到“${text}”`);
            }
            return ['Ctrl', 'Alt', 'Shift', 'Meta'].filter((m) => mods.includes(m)).map((m) => m + '+').join('') + code;
          };

          // What the page in the current tab answered to `page` or `do`, as output or as the reason it failed.
          // Exit 5: no page could be reached. Exit 1: a page answered, and the action did not happen.
          const clock = (t) => {
            const s = Math.max(0, Math.floor(t));
            const pad = (n) => String(n).padStart(2, '0');
            const h = Math.floor(s / 3600);
            return (h ? h + ':' + pad(Math.floor(s / 60) % 60) : Math.floor(s / 60)) + ':' + pad(s % 60);
          };
          const UNREACHED = {
            no_tab: 'Safari 没有打开的窗口',
            no_page: '当前标签页不是普通网页（起始页、设置页，或 Tempo 没有被允许的网站），Tempo 在那里不运行',
            not_ready: '页面还没读完 Tempo 的设置，稍后再试',
          };
          const REFUSED = {
            no_media: '当前标签页里没有视频或音频',
            site_off: '这个网站已对 Tempo 停用（tempo site <网站> enable 恢复）',
            tempo_off: 'Tempo 是关着的（tempo on 打开）',
            not_video: '画中画只对视频有效，这个页面播放的是音频',
            unsupported: '这个页面的视频不提供画中画接口',
            no_mark: '这个视频还没有记下位置（先 tempo do mark）',
            unknown_action: '这一版扩展不认识这个动作；装机的扩展比命令旧',
          };
          const pageReply = (command, action, r) => {
            if (r.error) {
              if (UNREACHED[r.error]) throw new Fail(5, r.error, UNREACHED[r.error]);
              if (r.error === 'not_allowed') {
                failed('not_allowed', action === 'pip' ? 'Safari 没有进入或退出画中画：画中画只接受真人按键触发'
                                                       : '网页没有开始播放：没有真人按键时，Safari 不让这个页面自己开始播放');
              }
              failed(REFUSED[r.error] ? r.error : 'failed', REFUSED[r.error] || `页面没有完成这个动作（${r.detail || r.error}）`);
            }
            if (!r.page) throw new Fail(5, 'no_answer', 'Safari 里的 Tempo 回答了，但没有带回页面信息');
            const page = r.page;
            const media = r.media || null;
            const where = `${page.host || '（没有主机名的页面）'}：${page.off ? '不生效（' + (page.site_off ? '本站停用' : 'Tempo 已关') + '）' : T.fmt(page.speed)}，${page.rule ? '单独速度（规则 ' + page.rule.host + '）' : '跟随全局速度'}`;
            const playing = media
              ? `${media.kind === 'audio' ? '音频' : '视频'} ${media.paused ? '已暂停' : '播放中'} ${clock(media.time)}${media.duration == null ? '' : ' / ' + clock(media.duration)}，${T.fmt(media.rate)}${media.muted ? '，静音' : ''}${media.pip ? '，画中画' : ''}${media.mark == null ? '' : '，记下的位置 ' + clock(media.mark)}`
              : page.has_media ? '页面里有视频或音频，但读不到它的状态' : '页面里没有视频或音频';
            if (command === 'page') return { out: JSON.stringify({ ok: true, page, media }), text: `  ${where}\n  ${playing}` };
            const name = T.ACTIONS.find(([x]) => x === action)[1];
            return { out: JSON.stringify({ ok: true, action, page, result: r.result || null, media }), text: `已执行：${name}\n  ${where}\n  ${playing}` };
          };

          try {
            const raw = {};
            for (const k of Object.keys(input.rows)) { try { raw[k] = JSON.parse(input.rows[k]); } catch (e) {} }
            const cfg = T.normalize(raw);
            const a = input.args;
            const want = (min, max, form) => { if (a.length < min || a.length > max) usage('bad_arguments', `用法：tempo ${form}`); };
            const noSite = () => { if (input.site != null) usage('unexpected_option', '--site 只用于 show 和 speed；site 命令直接写网站'); };
            let host = input.site == null ? '' : hostOf(input.site);
            let patch = null;
            let clear = false;
            const extra = {};

            switch (input.command) {
              case 'show': want(0, 0, 'show [--site 网站] [--json]'); break;
              case 'keys': noSite(); want(0, 0, 'keys [--json]'); break;
              case 'export': noSite(); want(0, 0, 'export [--json]'); break;
              case 'speed': {
                want(1, 1, 'speed <0.1–16|up|down|toggle> [--site 网站] [--json]');
                const move = { up: 'faster', down: 'slower', toggle: 'reset' }[a[0]];
                patch = T.speedPatch(cfg, host, move ? T.target(cfg, host, move) : number(a[0], '速度', T.MIN, T.MAX));
                break;
              }
              case 'on': case 'off':
                noSite(); want(0, 0, input.command + ' [--json]');
                patch = { enabled: input.command === 'on' };
                break;
              case 'site': {
                const form = 'site <网站> rule [速度] | follow | disable | enable [--json]';
                noSite(); want(2, 3, form);
                host = hostOf(a[0]);
                if (a[1] !== 'rule' && a.length > 2) usage('bad_arguments', `用法：tempo ${form}`);
                // A rule for example.com already covers its subdomains: change that one, do not add a second.
                if (a[1] === 'rule') {
                  const hit = T.match(cfg.rules, host);
                  patch = T.rulePatch(cfg, hit ? hit[0] : host, true, a.length > 2 ? number(a[2], '速度', T.MIN, T.MAX) : undefined);
                } else if (a[1] === 'follow') patch = T.rulePatch(cfg, host, false);
                else if (a[1] === 'disable') {
                  const hit = T.match(cfg.off, host);
                  patch = T.offPatch(cfg, hit ? hit[0] : host, true);
                } else if (a[1] === 'enable') patch = T.offPatch(cfg, host, false);
                else usage('bad_arguments', `用法：tempo ${form}`);
                break;
              }
              case 'set': {
                noSite(); want(2, 2, 'set step <0.01–1> | seek <1–600> | indicator <on|off> | remote <on|off> [--json]');
                if (a[0] === 'step') patch = { step: T.normalize({ step: number(a[1], '步长', 0.01, 1) }).step };
                else if (a[0] === 'seek') patch = { seek: number(a[1], '快进快退秒数', 1, 600, true) };
                else if (a[0] === 'indicator') patch = { indicator: onOff(a[1], '页面提示') };
                else if (a[0] === 'remote') patch = { remote: onOff(a[1], '命令通道') };
                else usage('unknown_setting', `可改的设置是 step、seek、indicator、remote，收到“${a[0]}”`);
                break;
              }
              case 'page': noSite(); want(0, 0, 'page [--json]'); break;
              case 'do':
                noSite(); want(1, 1, 'do <动作> [--json]');
                if (!T.ACTIONS.some(([x]) => x === a[0])) usage('unknown_action', `动作只能是 ${T.ACTIONS.map(([x]) => x).join('、')}，收到“${a[0]}”`);
                break;
              case 'bind': {
                noSite(); want(2, 2, 'bind <动作> <组合|none> [--json]');
                if (!T.ACTIONS.some(([x]) => x === a[0])) usage('unknown_action', `动作只能是 ${T.ACTIONS.map(([x]) => x).join('、')}，收到“${a[0]}”`);
                const bound = T.bindPatch(cfg, a[0], comboOf(a[1]));
                patch = bound.patch;
                extra.freed = bound.freed;
                break;
              }
              case 'import': {
                noSite(); want(1, 1, 'import <文件|-> [--json]');
                if (input.dry) break;
                let data;
                try { data = JSON.parse(input.text); } catch (e) { data = null; }
                if (!data || typeof data !== 'object' || Array.isArray(data)) failed('bad_config', '这段内容不是有效的配置，原配置没有改动');
                patch = T.normalize(data);
                break;
              }
              case 'defaults':
                noSite(); want(0, 0, 'defaults --yes [--json]');
                if (!input.yes) usage('confirmation_required', '恢复默认会把速度、网站规则和快捷键都改回初始值；确认后加 --yes');
                clear = true;
                break;
              default: usage('unknown_command', `没有“${input.command}”这个命令`);
            }

            if (input.command === 'page' || input.command === 'do') {
              if (input.dry) return JSON.stringify({ out: '{}', text: '', writes: {}, clear: false });
              return JSON.stringify(Object.assign(pageReply(input.command, a[0], input.remote || {}), { writes: {}, clear: false }));
            }

            const now = clear ? T.normalize({}) : patch ? T.normalize(Object.assign({}, cfg, patch)) : cfg;
            const view = (h) => {
              if (!h) return null;
              const s = T.state(now, h);
              return { host: h, speed: s.speed, off: s.off, site_off: s.siteOff, rule: s.rule ? { host: s.rule[0], speed: s.rule[1] } : null };
            };
            const site = view(host);
            const list = (map, each) => Object.keys(map).map(each).join('、') || '无';
            const summary = [
              `  开关        ${now.enabled ? '开' : '关'}`,
              `  全局速度    ${T.fmt(now.speed)}（上次速度 ${T.fmt(now.last)}）`,
              `  每次加减    ${now.step}`,
              `  快进快退    ${now.seek} 秒`,
              `  页面提示    ${now.indicator ? '开' : '关'}`,
              `  命令通道    ${now.remote ? '开' : '关'}`,
              `  单独记速度  ${list(now.rules, (k) => `${k} ${T.fmt(now.rules[k])}`)}`,
              `  停用的网站  ${list(now.off, (k) => k)}`,
            ];
            if (site) summary.push(`  ${site.host}：${site.off ? '不生效（' + (site.site_off ? '本站停用' : 'Tempo 已关') + '）' : T.fmt(site.speed)}，${site.rule ? '单独速度（规则 ' + site.rule.host + '）' : '跟随全局速度'}`);

            let out;
            let text;
            let outLive;
            let textLive;
            if (input.command === 'show') {
              out = { ok: true, version: input.version, settings: now, site, store: input.store || null };
              text = [`Tempo ${input.version} 的设置`].concat(summary).join('\n');
            } else if (input.command === 'keys') {
              const keys = T.ACTIONS.map(([action, name]) => ({ action, name, combo: now.keys[action], label: T.label(now.keys[action]) }));
              out = { ok: true, keys };
              text = keys.map((k) => `  ${k.action.padEnd(10)} ${k.label.padEnd(8)} ${k.name}`).join('\n');
            } else if (input.command === 'export') {
              out = { ok: true, config: now };
              text = JSON.stringify(now, null, 2);
            } else {
              const changed = clear ? now : patch || {};
              out = Object.assign({ ok: true, changed, settings: now, site, live: false }, extra);
              outLive = Object.assign({}, out, { live: true });
              const head = clear ? '已恢复默认' : '已写入 ' + Object.keys(changed).map((k) => `${k} = ${JSON.stringify(changed[k])}`).join('，');
              const freed = extra.freed ? `\n  这个组合原来用于 ${extra.freed}，已改到这里` : '';
              const later = patch && patch.remote === true
                ? '  已打开的页面要切到前台或刷新一次，命令通道才接上'
                : '  新打开或刷新的页面立即生效；已打开的页面切回时生效';
              text = [head + freed].concat(summary, later).join('\n');
              textLive = [head + freed].concat(summary, '  已通知 Safari 里打开着的页面，立即生效').join('\n');
            }
            const writes = {};
            if (patch) for (const k of Object.keys(patch)) writes[k] = JSON.stringify(patch[k]);
            return JSON.stringify({ out: JSON.stringify(out), text, writes, clear, outLive: outLive && JSON.stringify(outLive), textLive });
          } catch (e) {
            if (e instanceof Fail) return JSON.stringify({ fail: { exit: e.exit, code: e.code, message: e.message } });
            throw e;
          }
        }
        """#
}

/// Safari's own file for this extension's `storage.local`: one table, a key and its value as JSON text.
/// Safari writes it through SQLite too, so both sides can use it at the same time; a write from here raises
/// no change event in Safari, which is why pages read the settings again when they come back into view.
final class Store {
    let path: String
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func locate(profile: String) throws -> String {
        if let override = ProcessInfo.processInfo.environment["TEMPO_STORE"] { return override }
        let folder = NSHomeDirectory() + "/Library/Containers/com.apple.Safari/Data/Library/WebKit/WebExtensions/" + profile
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: folder)
        } catch let error as NSError {
            if error.code == NSFileReadNoSuchFileError {
                throw CLIFailure(exit: 4, code: "store_missing", message: "Safari 没有“\(profile)”这个个人资料的扩展数据目录")
            }
            throw CLIFailure(exit: 4, code: "store_unreadable",
                             message: "读不到 Safari 的扩展数据（\(error.localizedDescription)）；运行本命令的终端需要“完全磁盘访问权限”")
        }
        guard let name = entries.first(where: { $0.hasPrefix(extensionIdentifier + " (") }) else {
            throw CLIFailure(exit: 4, code: "store_missing", message: "Safari 里还没有 Tempo 的设置存储（扩展第一次写入时才建）；先在 Safari 的 Tempo 面板里改一项设置或导入一次配置")
        }
        return folder + "/" + name + "/LocalStorage.db"
    }

    init(path: String, writable: Bool) throws {
        self.path = path
        if access(path, F_OK) != 0 {
            let missing = errno == ENOENT
            throw CLIFailure(exit: 4, code: missing ? "store_missing" : "store_unreadable",
                             message: missing ? "Safari 里还没有 Tempo 的设置存储（扩展第一次写入时才建）；先在 Safari 的 Tempo 面板里改一项设置或导入一次配置"
                                              : "读不到 Safari 的扩展数据；运行本命令的终端需要“完全磁盘访问权限”")
        }
        // Never created from here: the file is Safari's.
        guard sqlite3_open_v2(path, &db, writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            close()
            throw CLIFailure(exit: 4, code: "store_unreadable", message: "打不开 Safari 里 Tempo 的设置存储（\(reason)）")
        }
        sqlite3_busy_timeout(db, 3000)
        let columns = try query("SELECT name FROM pragma_table_info('extension_storage') ORDER BY cid").map { $0[0] }
        let version = try query("PRAGMA user_version").first?[0] ?? ""
        // Reading only needs the table; writing is limited to the layout this was checked against.
        guard columns == ["key", "value"], !writable || version == "2" else {
            close()
            throw CLIFailure(exit: 4, code: "store_unsupported",
                             message: "Safari 的扩展存储格式变了（列 \(columns)，版本 \(version)），为免写坏不处理；请更新 Tempo")
        }
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    func rows() throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try query("SELECT key, value FROM extension_storage") { result[row[0]] = row[1] }
        return result
    }

    func begin() throws { _ = try query("BEGIN IMMEDIATE") }
    func commit() throws { _ = try query("COMMIT") }
    func rollback() { _ = try? query("ROLLBACK") }

    func apply(writes: [String: String], clear: Bool) throws {
        if clear { _ = try query("DELETE FROM extension_storage") }
        for (key, value) in writes {
            _ = try query("INSERT INTO extension_storage (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                          [key, value])
        }
    }

    private func query(_ sql: String, _ arguments: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        var code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        for (offset, argument) in arguments.enumerated() where code == SQLITE_OK {
            code = sqlite3_bind_text(statement, Int32(offset + 1), argument, -1, Store.transient)
        }
        var rows: [[String]] = []
        while code == SQLITE_OK || code == SQLITE_ROW {
            code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                })
            }
        }
        guard code == SQLITE_DONE else {
            let reason = String(cString: sqlite3_errmsg(db))
            let busy = code == SQLITE_BUSY || code == SQLITE_LOCKED
            throw CLIFailure(exit: busy ? 1 : 4, code: busy ? "store_busy" : "store_unreadable",
                             message: busy ? "Safari 正在写设置，稍后再试（\(reason)）" : "读写 Safari 里 Tempo 的设置存储失败（\(reason)）")
        }
        return rows
    }
}
#endif
