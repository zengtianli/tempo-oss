import AppKit
import SafariServices
import notify

/// The command line's half of the mailbox (Shared/Mailbox.swift): how `tempo page` and `tempo do` reach the
/// page in Safari's current tab, and how a settings command tells open pages to read the settings again.
///
/// Nothing here launches or activates Safari, opens a window or sends a key. Safari is never called: a
/// request is a file in the extension's container plus a notification without content, and it is heard only
/// while the extension's background page has a message parked (the "remote" setting is on and some open page
/// has media). When nobody is listening the command says so and exits 5.
enum Remote {
    static func unreachable(_ code: String, _ message: String) -> CLIFailure {
        CLIFailure(exit: 5, code: code, message: message)
    }

    static func safariRunning() -> Bool {
        let bundle = ProcessInfo.processInfo.environment["TEMPO_SAFARI_BUNDLE"] ?? "com.apple.Safari"
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    /// Whether an extension process says it is listening for this Safari profile: its mark is fresh, names
    /// the profile, and the process is still there.
    static func armed(profile: String) -> Bool {
        guard let mark = Mailbox.read(Mailbox.armed), let pid = mark["pid"] as? Int, pid > 0,
              Date().timeIntervalSince1970 - (mark["at"] as? Double ?? 0) < Mailbox.holdTime + 10,
              let profiles = mark["profiles"] as? [String] else { return false }
        let wanted = profile == "Default" ? "" : profile
        guard profiles.contains(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Sends one request and waits for the page's answer. Throws exit 5 with the reason when it cannot get
    /// there: Safari is not running, the setting is off, the extension is disabled, no page is listening, or
    /// nothing came back in time (the request is then withdrawn, so it cannot run later).
    static func send(action: String, profile: String, timeout: TimeInterval = 3) throws -> [String: Any] {
        guard safariRunning() else {
            throw unreachable("safari_not_running", "Safari 没有在运行；本命令不会去启动它")
        }
        // The settings store is looked at first. Without Full Disk Access that fails the way every other
        // command does (exit 4), before the extension's own folder is touched.
        let setting = try remoteSetting(profile: profile)
        guard armed(profile: profile) else { throw asleep(setting) }

        let id = UUID().uuidString
        var request: [String: Any] = ["id": id, "action": action, "at": Date().timeIntervalSince1970]
        if profile != "Default" { request["profile"] = profile }
        guard Mailbox.write(request, to: Mailbox.request) else {
            throw unreachable("mailbox_unwritable", "写不进 Tempo 扩展的收件目录；运行本命令的终端需要“完全磁盘访问权限”")
        }
        notify_post(Mailbox.bell)

        let deadline = Date().addingTimeInterval(timeout)
        let reply = Mailbox.reply(id)
        while Date() < deadline {
            if let answer = Mailbox.read(reply) {
                try? FileManager.default.removeItem(at: reply)
                return answer["reply"] as? [String: Any] ?? [:]
            }
            usleep(20_000)
        }
        if Mailbox.read(Mailbox.request)?["id"] as? String == id { try? FileManager.default.removeItem(at: Mailbox.request) }
        try? FileManager.default.removeItem(at: reply)
        throw unreachable("no_answer", "Safari 里的 Tempo 在 \(Int(timeout)) 秒内没有回答，请求已撤回；多半是后台页刚被 Safari 回收，把播放页切到前台一次再试")
    }

    /// After a settings command has written the store: asks every open page to read the settings again.
    /// True when Safari's side confirmed it; false, without waiting, when nobody is listening.
    static func nudge(profile: String) -> Bool {
        guard safariRunning(), armed(profile: profile) else { return false }
        return (try? send(action: "reread", profile: profile, timeout: 1.5))?["reread"] != nil
    }

    /// The stored "remote" setting: true, false, or nil when Safari has no store for Tempo yet (then the
    /// setting is at its default, off). An unreadable store is an error, as in every other command.
    private static func remoteSetting(profile: String) throws -> Bool? {
        do {
            let store = try Store(path: try Store.locate(profile: profile), writable: false)
            defer { store.close() }
            return try store.rows()["remote"] == "true"
        } catch let failure as CLIFailure where failure.code == "store_missing" {
            return nil
        }
    }

    /// Why nobody is listening, as precisely as it can be told without asking Safari to do anything.
    private static func asleep(_ setting: Bool?) -> CLIFailure {
        if setting != true {
            return unreachable("channel_off", "命令通道没有打开：先 tempo set remote on（或在 Tempo 面板“快捷键与设置”里勾选），再把播放页切到前台或刷新一次")
        }
        if isNotarized(), extensionEnabled() == false {
            return unreachable("extension_disabled", "Tempo 扩展在 Safari 里没有启用（Safari 设置 > 扩展里勾选它）")
        }
        return unreachable("channel_asleep", "Safari 里现在没有在听命令的页面：通道只在有带视频或音频的网页开着时才醒着；刚打开开关的话，把播放页切到前台或刷新一次")
    }

    /// Safari's own answer about the extension, or nil when it does not say within two seconds.
    private static func extensionEnabled() -> Bool? {
        var enabled: Bool?
        var done = false
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionIdentifier) { state, _ in
            enabled = state?.isEnabled
            done = true
        }
        let deadline = Date().addingTimeInterval(2)
        while !done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return enabled
    }
}
