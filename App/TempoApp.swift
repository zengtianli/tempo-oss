import SafariServices
import SwiftUI

/// Tempo lives in Safari. This app only carries the extension, reports whether it is switched on and
/// opens the right Safari settings page.
let extensionIdentifier = "cyou.tianli.tempo.extension"

/// Safari lists an extension from outside the App Store only when its app is notarized. Safari's own state
/// call still answers "not enabled" for a build it has not listed, so this is checked separately.
func isNotarized() -> Bool {
    #if APP_STORE
    // Store distribution is validated by Apple, not Developer ID notarization.
    return true
    #else
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }
    return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    #endif
}

/// `Tempo status [--json]` answers from the command line without opening a window:
/// exit 0 = enabled in Safari, 1 = installed but not enabled, 2 = Safari could not report it,
/// 3 = this build is not notarized, so Safari does not list it.
/// Every other command reads or changes the settings and is in TempoCLI.swift.
/// The window opens only when there are no arguments at all (or only the flags the system adds on launch);
/// an option nobody knows in first place is a usage error (exit 2), like anywhere else.
@main
enum Main {
    /// ~/.local/bin/tempo is a symlink into the app. Started through it, the process would take the
    /// symlink's folder for its bundle and Safari would not accept it as the extension's app, so it starts
    /// itself again at the real path first.
    static func reexecAtRealPath() {
        #if !APP_STORE
        guard getenv("TEMPO_REEXEC") == nil else { return }
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0, let real = realpath(path, nil) else { return }
        defer { free(real) }
        guard strcmp(path, real) != 0 else { return }
        setenv("TEMPO_REEXEC", "1", 1)
        execv(real, CommandLine.unsafeArgv)   // returns only on failure; then carry on in place
        #endif
    }

    /// Arguments the system or Xcode may hand to an app it launches: `-psn_0_1234`,
    /// `-NSDocumentRevisionsDebugMode YES`, `-AppleLanguages (zh)`. Any other word that starts with a dash was
    /// typed by a caller and is a usage error, never a reason to open the window.
    static func isLaunchFlag(_ word: String) -> Bool {
        ["-psn_", "-NS", "-Apple"].contains { word.hasPrefix($0) }
    }

    /// The window. Tests set TEMPO_NO_WINDOW, so a wrong turn in the routing below shows up as exit 70
    /// instead of a window on screen.
    static func openWindow() -> Never {
        if getenv("TEMPO_NO_WINDOW") != nil { exit(70) }
        TempoApp.main()
        exit(0)
    }

    static func main() {
        #if !APP_STORE
        if CommandLine.arguments.dropFirst().first == "--ui-self-test" { TempoBasics.selfTest(); exit(0) }
        if CommandLine.arguments.dropFirst().first == "--update-source-self-test" { TempoBasics.liveUpdateSelfTest() }
        if AppLifecycleCLI.handles(CommandLine.arguments.dropFirst().first) {
            exit(TempoBasics.shared.command(Array(CommandLine.arguments.dropFirst())))
        }
        #endif
        #if APP_STORE
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--store-self-test"] { StoreSelfTest.run() }
        guard args.isEmpty || args.first.map(isLaunchFlag) == true else {
            FileHandle.standardError.write(Data("Tempo App Store edition has no command-line interface. Open the app to manage the Safari extension.\n".utf8))
            exit(2)
        }
        openWindow()
        #else
        reexecAtRealPath()
        let args = Array(CommandLine.arguments.dropFirst())
        let json = args.contains("--json")
        switch args.first {
        case nil:
            openWindow()
        case "status":
            // `status` takes --json and nothing else.
            if let extra = args.dropFirst().first(where: { $0 != "--json" }) {
                CLI.fail(extra.hasPrefix("-")
                    ? CLIFailure(exit: 2, code: "unknown_option", message: "不认识的参数 \(extra)")
                    : CLIFailure(exit: 2, code: "bad_arguments", message: "用法：tempo status [--json]"), json: json)
            }
        case "--help", "-h", "help":
            print(CLI.usage)
            print(AppLifecycleCLI.help("tempo"))
            exit(0)
        case .some(let word) where !word.hasPrefix("-"):
            CLI.run(args)   // settings commands; an unknown one exits 2
        case .some(let word) where isLaunchFlag(word):
            openWindow()    // launched as an app with system-supplied flags
        case .some(let word):
            CLI.fail(CLIFailure(exit: 2, code: "unknown_option", message: CLI.options.contains(word)
                ? "\(word) 要写在命令之后，例如 tempo show \(word)"
                : "不认识的参数 \(word)"), json: json)
        }
        if !isNotarized() {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            print(args.contains("--json")
                ? "{\"version\":\"\(version)\",\"enabled\":null,\"notarized\":false}"
                : "Tempo \(version): this build is not notarized, so Safari does not list the extension. Run scripts/notarize.sh and install again.")
            exit(3)
        }
        var code: Int32 = 2
        var line = ""
        var done = false
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionIdentifier) { state, error in
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            if let state {
                code = state.isEnabled ? 0 : 1
                line = args.contains("--json")
                    ? "{\"version\":\"\(version)\",\"enabled\":\(state.isEnabled)}"
                    : "Tempo \(version): \(state.isEnabled ? "enabled in Safari" : "installed, not enabled in Safari")"
            } else {
                let reason = (error?.localizedDescription ?? "no answer").replacingOccurrences(of: "\"", with: "'")
                line = args.contains("--json")
                    ? "{\"version\":\"\(version)\",\"enabled\":null,\"error\":\"\(reason)\"}"
                    : "Tempo \(version): Safari did not report the extension (\(reason))"
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(8)
        while !done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        print(done ? line : "Tempo: Safari did not answer within 8 s")
        exit(code)
        #endif
    }
}

struct TempoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Tempo · 倍速", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !APP_STORE
        TempoBasics.shared.install()
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @State private var enabled: Bool?
    @State private var problem: String?
    private let notarized = isNotarized()

    private let shortcuts: [(String, String)] = [
        ("D", "加速"), ("A", "减速"), ("S", "1× / 上次速度"),
        ("X", "快进"), ("Z", "快退"), ("⇧X  ⇧Z", "逐帧"),
        ("⇧W", "记下位置"), ("W", "回到记下的位置"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tempo · 倍速").font(.title2.weight(.semibold))
                    Text("给 Safari 里所有网页视频和音频设一个播放速度。")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                HStack {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(statusText)
                    Spacer()
                    Button("打开 Safari 扩展设置") { openSettings() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(4)
            }

            if !notarized {
                Text("这一版没有经过苹果公证，Safari 不会把它列在“扩展”里。请装公证过的版本。")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if enabled == true {
                Text("按键没反应时：在视频页点工具栏上的 Tempo 图标，选“始终允许在每个网站上”，再刷新页面。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("在 Safari 设置的“扩展”里勾选 Tempo，并把网站权限设为“在所有网站上始终允许”。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("默认快捷键").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    ForEach(shortcuts, id: \.0) { key, name in
                        GridRow {
                            Text(key).font(.system(.body, design: .monospaced))
                            Text(name).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("页面里有视频或音频、且没有在输入文字时生效；可在工具栏的 Tempo 面板里改键。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            #if !APP_STORE
            Button("设置与更新…") { AppLifecycleUI.shared.show() }
            #endif
        }
        .padding(22)
        .frame(width: 440)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var statusColor: Color {
        switch enabled {
        case .some(true): return .green
        case .some(false): return .orange
        case .none: return .gray
        }
    }

    private var statusText: String {
        if let problem { return problem }
        switch enabled {
        case .some(true): return "已在 Safari 中启用"
        case .some(false): return "还没有在 Safari 中启用"
        case .none: return "正在读取状态…"
        }
    }

    private func refresh() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionIdentifier) { state, error in
            DispatchQueue.main.async {
                enabled = state?.isEnabled
                problem = error == nil ? nil : "读不到扩展状态，请先打开一次 Safari"
            }
        }
    }

    private func openSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionIdentifier) { _ in }
    }
}
