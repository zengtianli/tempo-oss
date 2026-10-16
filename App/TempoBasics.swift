#if !APP_STORE
import AppKit

/// Product adapter only: settings rules remain in shared.js; sync/update transactions are shared.
final class TempoBasics: NSObject {
    static let publicManifest = URL(string: "https://github.com/zengtianli/tempo-oss/releases/latest/download/release-manifest.json")!
    static let shared = TempoBasics()
    static let portable = ["enabled", "speed", "last", "step", "seek", "indicator", "rules", "off", "keys"]
    let defaults: UserDefaults
    let file: URL
    let configuration: AppConfiguration
    let speed = NSTextField(string: "1")
    let message = AppLifecycleUI.detailLabel()
    let indicator = NSSwitch()
    let refreshToggle = NSSwitch()
    let refreshKey = NSTextField(string: "r")
    let refreshDescription = AppLifecycleUI.detailLabel()
    let save = NSButton(title: "保存播放速度", target: nil, action: nil)
    let saveKey = NSButton(title: "保存 ⌘ 快捷键", target: nil, action: nil)
    var refreshCount = 0
    var applyError: Error?
    private var storeWatch: DispatchSourceFileSystemObject?
    lazy var shortcuts = AppShortcuts(defaults: defaults) { [weak self] in self?.refresh() }
    var source: AppUpdateSource {
        let env = ProcessInfo.processInfo.environment
        if env["APP_LIFECYCLE_SUPPORT_DIR"] != nil && env["TEMPO_BASICS_LIVE_UPDATES"] != "1" { return .privateCloud(channel: "isolated") }
        // Existing anonymous Release asset, no API token/rate-limit dependency and an exact build number.
        return .manifest(Self.publicManifest)
    }
    override init() {
        let env = ProcessInfo.processInfo.environment
        if let suite = env["TEMPO_BASICS_SUITE"], suite != Bundle.main.bundleIdentifier { defaults = UserDefaults(suiteName: suite)! }
        else { defaults = .standard }
        let root = env["APP_LIFECYCLE_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tempo")
        file = root.appendingPathComponent("portable-settings.json")
        configuration = AppConfiguration(productID: "cyou.tianli.tempo", defaultsKeys: AppShortcuts.portableKeys,
            files: [AppConfigurationFile(url: file, keys: Self.portable, validateField: Self.validate)], defaults: defaults,
            validateDefault: { key, value in
                if key == AppShortcuts.enabledKey { guard value is NSNumber else { throw AppUpdateError("快捷键开关无效") } }
                else {
                    guard let b = value as? [String: Any], let k = b["key"] as? String, let m = b["modifiers"] as? NSNumber else { throw AppUpdateError("快捷键格式无效") }
                    try AppShortcuts.validate(.init(key: k, modifiers: NSEvent.ModifierFlags(rawValue: m.uintValue)))
                }
            })
        super.init()
        configuration.onChange = { [weak self] in
            guard let self else { return }
            do { try self.apply(); self.refresh() } catch { self.applyError = error; self.message.stringValue = "配置未写入 Safari：\(error.localizedDescription)" }
        }
        save.target = self; save.action = #selector(saveSpeed)
        indicator.target = self; indicator.action = #selector(saveIndicator)
        refreshToggle.target = self; refreshToggle.action = #selector(toggleRefresh)
        saveKey.target = self; saveKey.action = #selector(changeKey)
    }
    static func validate(_ key: String, _ value: Any) throws {
        switch key {
        case "speed", "last", "step", "seek":
            let range: ClosedRange<Double> = key == "step" ? 0.01...1 : key == "seek" ? 1...600 : 0.1...16
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), range.contains(n.doubleValue), n.doubleValue.isFinite else { throw AppUpdateError("\(key) 超出有效范围") }
        case "enabled", "indicator":
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw AppUpdateError("开关格式无效") }
        case "rules":
            guard let rules = value as? [String: Any] else { throw AppUpdateError("网站规则无效") }
            for (_, speed) in rules { try validate("speed", speed) }
        case "off": guard let map = value as? [String: Bool], map.values.allSatisfy({ $0 }) else { throw AppUpdateError("停用网站列表无效") }
        case "keys":
            guard let keys = value as? [String: String], Set(keys.values.filter { !$0.isEmpty }).count == keys.values.filter({ !$0.isEmpty }).count else { throw AppUpdateError("媒体快捷键重复或格式无效") }
        default: throw AppUpdateError("不可迁移字段")
        }
    }
    func settings() throws -> [String: Any] {
        let result = try CLI.execute(["show", "--json"])
        return (try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as! [String: Any])["settings"] as! [String: Any]
    }
    func capture() throws {
        let value = try settings().filter { Self.portable.contains($0.key) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
    }
    func apply() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        for (key, item) in value { try Self.validate(key, item) }
        let local = try settings()
        if NSDictionary(dictionary: value).isEqual(to: local.filter { Self.portable.contains($0.key) }) { return }
        // The local command channel is a per-device capability and never travels through iCloud.
        value["remote"] = local["remote"]
        let incoming = file.deletingLastPathComponent().appendingPathComponent("apply-settings.json")
        try JSONSerialization.data(withJSONObject: value).write(to: incoming, options: .atomic)
        defer { try? FileManager.default.removeItem(at: incoming) }
        _ = try CLI.execute(["import", incoming.path, "--json"])
    }
    func command(_ args: [String]) -> Int32 {
        do { try capture() } catch { // Update checks still work before Safari has created its store.
            if args.first == "config" { print("{\"ok\":false,\"error\":\"Safari settings unavailable\"}"); return 4 }
        }
        var product = AppLifecycleCLI.Product(command: "tempo", name: "Tempo · 倍速", configuration: configuration, updateSource: source)
        product.changed = { [weak self] in
            do { try self?.apply() } catch { self?.applyError = error }
        }
        let code = AppLifecycleCLI.run(args, product: product)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return applyError == nil ? code : 1
    }
    func install() {
        try? capture()
        AppLifecycleUI.shared.productGroups = { [weak self] in self?.groups() ?? [] }
        AppLifecycleUI.shared.willShow = { [weak self] in self?.refresh() }
        AppLifecycleUI.install(name: "Tempo · 倍速", configuration: configuration, updateSource: source)
        AppLifecycleCLI.follow(configuration)
        shortcuts.installMenu()
        // Event driven and limited to the window app's lifetime: no daemon, timer or Safari launch.
        if let path = try? Store.locate(profile: "Default") {
            let fd = open(URL(fileURLWithPath: path).deletingLastPathComponent().path, O_EVTONLY)
            if fd >= 0 {
                let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
                watch.setEventHandler { [weak self] in
                    guard let self else { return }; do { try self.capture(); self.configuration.reconcile() } catch { self.message.stringValue = error.localizedDescription }
                }
                watch.setCancelHandler { close(fd) }; watch.resume(); storeWatch = watch
            }
        }
    }
    func groups() -> [NSView] {
        speed.widthAnchor.constraint(equalToConstant: 65).isActive = true
        refreshKey.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let edit = NSStackView(views: [speed, save]); edit.spacing = 8
        let key = NSStackView(views: [refreshKey, saveKey]); key.spacing = 8
        return [AppLifecycleUI.group("Safari 播放设置", rows: [
            AppLifecycleUI.row("播放速度", detail: message, accessory: edit),
            AppLifecycleUI.row("页面速度提示", accessory: indicator),
            AppLifecycleUI.row("媒体快捷键", detail: AppLifecycleUI.detailLabel("Safari 工具栏 Tempo → 快捷键与设置；tempo keys / bind 读写同一份配置。"))]),
            AppLifecycleUI.group("本 App 快捷键", rows: [
                AppLifecycleUI.row("刷新状态（只在 Tempo 内）", detail: refreshDescription, accessory: refreshToggle),
                AppLifecycleUI.row("⌘ 加字母或数字", accessory: key)])]
    }
    func refresh() {
        refreshCount += 1
        try? capture()
        do {
            let s = try settings(); speed.stringValue = String(describing: s["speed"]!); indicator.state = (s["indicator"] as? Bool) == true ? .on : .off
            message.stringValue = "与 Safari 面板共用配置；速度 0.1–16×"
        } catch { message.stringValue = "Safari 设置未就绪：\(error.localizedDescription)" }
        refreshToggle.state = shortcuts.enabled ? .on : .off; refreshKey.stringValue = shortcuts.binding.key
        refreshDescription.stringValue = shortcuts.descriptionText
    }
    @objc func saveSpeed() {
        do { _ = try CLI.execute(["speed", speed.stringValue, "--json"]); try capture(); configuration.reconcile(); refresh() }
        catch { message.stringValue = "未保存；原设置保留：\(error.localizedDescription)" }
    }
    @objc func saveIndicator() {
        do { _ = try CLI.execute(["set", "indicator", indicator.state == .on ? "on" : "off", "--json"]); try capture(); configuration.reconcile() }
        catch { message.stringValue = "未保存；原设置保留" }
    }
    @objc func toggleRefresh() { shortcuts.setEnabled(refreshToggle.state == .on); refreshDescription.stringValue = shortcuts.descriptionText }
    @objc func changeKey() {
        do { try shortcuts.setBinding(.init(key: refreshKey.stringValue.lowercased(), modifiers: .command)); refreshDescription.stringValue = shortcuts.descriptionText }
        catch { message.stringValue = error.localizedDescription }
    }
    /// A re-identified fixture must validate the public package against the production identity, while
    /// keeping preference writes in its disposable identity. Same fetch/parser as the production checker.
    static func liveUpdateSelfTest() -> Never {
        guard ProcessInfo.processInfo.environment["APP_LIFECYCLE_SUPPORT_DIR"] != nil,
              ProcessInfo.processInfo.environment["TEMPO_BASICS_SUITE"]?.hasPrefix("test.") == true else { exit(2) }
        var done = false
        var result: [String: Any] = [:]
        var code: Int32 = 1
        AppUpdateChecker.fetch(publicManifest) { response in
            defer { done = true }
            do {
                let data = try response.get()
                let release = try AppUpdateChecker.manifest(data, at: publicManifest, bundleID: "cyou.tianli.tempo")
                result = ["version": release.version, "build": release.build, "bundle_id": release.bundleID ?? "",
                          "download_url": release.downloadURL?.absoluteString ?? "", "sha256": release.sha256 ?? "",
                          "source_url": publicManifest.absoluteString]
                code = 0
            } catch { result = ["error": error.localizedDescription] }
        }
        let limit = Date().addingTimeInterval(25)
        while !done && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let data = (try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys)) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self)); exit(code)
    }
    static func selfTest() {
        guard let out = ProcessInfo.processInfo.environment["SOP_OUT_DIR"], ProcessInfo.processInfo.environment["APP_LIFECYCLE_SUPPORT_DIR"] != nil,
              ProcessInfo.processInfo.environment["TEMPO_STORE"] != nil, ProcessInfo.processInfo.environment["TEMPO_BASICS_SUITE"]?.hasPrefix("test.") == true else { exit(2) }
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let menu = NSMenu(); let app = NSMenuItem(); app.submenu = NSMenu(); menu.addItem(app); NSApp.mainMenu = menu
        let b = shared; b.install(); b.refresh()
        var checks: [String: Bool] = [:]
        b.speed.stringValue = "1.75"; b.save.performClick(nil)
        checks["settings.interaction"] = (try? b.settings()["speed"] as? Double) == 1.75
        let before = try? b.settings() as NSDictionary
        b.speed.stringValue = "bad"; b.save.performClick(nil)
        checks["settings.error_preserves_data"] = (try? b.settings() as NSDictionary) == before
        _ = try? CLI.execute(["speed", "2", "--json"])
        let count = b.refreshCount; b.shortcuts.performAction()
        checks["shortcuts.action_path"] = b.refreshCount == count + 1 && b.speed.stringValue == "2"
        b.speed.stringValue = "1.75"; b.save.performClick(nil)
        b.refreshToggle.state = .off; b.toggleRefresh()
        let disabled = b.shortcuts.menuItem?.keyEquivalent == "" && !b.shortcuts.enabled
        b.refreshToggle.state = .on; b.toggleRefresh()
        checks["shortcuts.disable_restore"] = disabled && b.shortcuts.enabled && b.shortcuts.menuItem?.keyEquivalent == "r"
        b.refreshKey.stringValue = "k"; b.saveKey.performClick(nil)
        checks["shortcuts.custom_binding"] = b.shortcuts.binding.key == "k" && b.shortcuts.menuItem?.keyEquivalent == "k" && b.refreshDescription.stringValue.contains("⌘K")
        b.refreshKey.stringValue = "r"; b.saveKey.performClick(nil)
        do { try b.shortcuts.setBinding(.init(key: "q", modifiers: .command)); checks["shortcuts.conflict_or_reserved_keys"] = false }
        catch { checks["shortcuts.conflict_or_reserved_keys"] = b.shortcuts.binding.key == "r" }
        do {
            let root = URL(fileURLWithPath: out); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for (name, result) in try AppLifecycleUI.shared.offscreenSnapshot(to: root.appendingPathComponent("settings-\(label).png"), appearance: appearance) { checks["ui.\(label).\(name)"] = result }
            }
            checks["ui.never_visible_or_key"] = NSApp.windows.allSatisfy { !$0.isVisible && !$0.isKeyWindow }
            AppLifecycleUI.shared.checkForUpdates(present: false)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let history = AppUpdatePreferences.status(Bundle.main.bundleIdentifier!, source: b.source)["history"] as? [String: Any]
            checks["updates.actual_check_action"] = history?["last_attempt_at"] != nil
            // Closing the actual offscreen settings windows exercises the normal close path.
            NSApp.windows.forEach { $0.performClose(nil) }
            checks["ui.close_action"] = NSApp.windows.allSatisfy { !$0.isVisible }
            let data = try JSONSerialization.data(withJSONObject: ["checks": checks], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent("ui-self-test.json")); print(String(decoding: data, as: UTF8.self))
        } catch { fputs("\(error)\n", stderr); exit(1) }
        exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }
}
#endif
