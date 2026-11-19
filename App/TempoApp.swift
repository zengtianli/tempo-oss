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
        if CommandLine.arguments.dropFirst().first == "--l10n-self-test" { TempoLocalizationAcceptance.run() }
        if CommandLine.arguments.dropFirst().first == "--ui-self-test" { TempoBasics.selfTest(); exit(0) }
        if CommandLine.arguments.dropFirst().first == "--update-source-self-test" { TempoBasics.liveUpdateSelfTest() }
        // `tempo feed <latest.json>`: read a release record with this app's own parser before it is published.
        if AppUpdateFeed.handles(CommandLine.arguments.dropFirst().first) {
            exit(AppUpdateFeed.run(Array(CommandLine.arguments.dropFirst()), bundleID: TempoBasics.bundleID))
        }
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
        Window("Tempo", id: "main") {
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
    private let notarized: Bool
    private let observesSafari: Bool

    init() {
        notarized = isNotarized()
        observesSafari = true
    }

    /// Uses the production view without contacting Safari or opening a window during visual acceptance.
    init(previewEnabled: Bool?, previewNotarized: Bool, previewProblem: String? = nil) {
        _enabled = State(initialValue: previewEnabled)
        _problem = State(initialValue: previewProblem)
        notarized = previewNotarized
        observesSafari = false
    }

    private let shortcuts: [(String, LocalizedStringKey)] = [
        ("D", "Speed up"), ("A", "Slow down"), ("S", "1× / Previous speed"),
        ("X", "Seek forward"), ("Z", "Seek backward"), ("⇧X  ⇧Z", "Step through frames"),
        ("⇧W", "Save playback position"), ("W", "Return to saved position"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tempo").font(.title2.weight(.semibold))
                    Text("Set one playback speed for video and audio across Safari.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox {
                HStack(alignment: .center, spacing: 12) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(statusText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Safari Extension Settings") { openSettings() }
                        .keyboardShortcut(.defaultAction)
                        .fixedSize()
                }
                .padding(4)
            }

            if !notarized {
                Text("This build has not been notarized by Apple, so Safari will not list the extension. Install a notarized version.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if enabled == true {
                Text("If shortcuts do not respond, click Tempo in Safari’s toolbar on the video page, choose “Always Allow on Every Website,” then reload the page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Enable Tempo in Safari Settings → Extensions, then set website access to “Always Allow on Every Website.”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Default Shortcuts").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    ForEach(shortcuts, id: \.0) { key, name in
                        GridRow {
                            Text(key).font(.system(.body, design: .monospaced))
                            Text(name).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Shortcuts work on pages with video or audio while you are not typing. Customize them in Tempo’s toolbar panel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            #if !APP_STORE
            // The standard settings entry: the same 设置… window ⌘, opens (swift-shared「标准设置入口模块」).
            Button("Settings…") { AppLifecycleUI.openStandardSettings() }
            #endif
        }
        .padding(22)
        .frame(width: 500)
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
        case .some(true): return String(localized: "Enabled in Safari")
        case .some(false): return String(localized: "Not enabled in Safari")
        case .none: return String(localized: "Checking status…")
        }
    }

    private func refresh() {
        guard observesSafari else { return }
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionIdentifier) { state, error in
            DispatchQueue.main.async {
                enabled = state?.isEnabled
                problem = error == nil ? nil : String(localized: "Unable to check the extension. Open Safari, then try again.")
            }
        }
    }

    private func openSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionIdentifier) { _ in }
    }
}
