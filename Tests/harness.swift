import AppKit
import WebKit

// Loads Tests/page.html in an offscreen WKWebView with the extension's scripts injected the way Safari
// injects them (engine in the page world; shared + engine + content in an isolated world), then runs
// Tests/cases.js and Tests/unit.js. The background page's script runs in a world of its own, with
// Tests/bgshim.js for its API, and is checked by Tests/remote.js. No window is created and nothing is
// activated.
//
//   harness <Extension/Resources> <Tests> [--no-page-engine]
//
// With --no-page-engine the page-world engine is left out. The run passes only if every ordinary check
// still passes through the standby engine and every check marked needsPageEngine fails, which shows those
// checks can tell the difference.

struct Check: Decodable {
    let name: String
    let ok: Bool
    let detail: String
    let needsPageEngine: Bool?
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: harness <resources> <tests> [--no-page-engine]\n".data(using: .utf8)!)
    exit(2)
}
let resources = URL(fileURLWithPath: args[1])
let tests = URL(fileURLWithPath: args[2])
let pageEngine = !args.contains("--no-page-engine")

func read(_ url: URL) -> String {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        FileHandle.standardError.write("cannot read \(url.path)\n".data(using: .utf8)!)
        exit(2)
    }
    return text
}

func spin(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return done()
}

final class Navigation: NSObject, WKNavigationDelegate {
    var finished = false
    var failure: String?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = "\(error)" }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = "\(error)" }
}

NSApplication.shared.setActivationPolicy(.prohibited)

let config = WKWebViewConfiguration()
config.mediaTypesRequiringUserActionForPlayback = []
let world = WKContentWorld.world(name: "tempo")
let scripts = config.userContentController
if pageEngine {
    scripts.addUserScript(WKUserScript(source: read(resources.appendingPathComponent("engine.js")),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
}
for url in [tests.appendingPathComponent("shim.js"),
            resources.appendingPathComponent("shared.js"),
            resources.appendingPathComponent("engine.js"),
            resources.appendingPathComponent("content.js")] {
    scripts.addUserScript(WKUserScript(source: read(url), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
}

// The background page is not a content script; it only shares this view as a place to run.
let background = WKContentWorld.world(name: "tempo-background")
for url in [tests.appendingPathComponent("bgshim.js"), resources.appendingPathComponent("background.js")] {
    scripts.addUserScript(WKUserScript(source: read(url), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: background))
}

let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
let navigation = Navigation()
web.navigationDelegate = navigation
web.loadFileURL(tests.appendingPathComponent("page.html"), allowingReadAccessTo: tests)
guard spin(15, until: { navigation.finished || navigation.failure != nil }), navigation.failure == nil else {
    print("FAIL  page did not load: \(navigation.failure ?? "timeout")")
    exit(1)
}

func run(_ file: String, in contentWorld: WKContentWorld) -> [Check] {
    var output: String?
    var problem: String?
    web.callAsyncJavaScript(read(tests.appendingPathComponent(file)), arguments: ["pageEngine": pageEngine],
                            in: nil, in: contentWorld) { result in
        switch result {
        case .success(let value): output = value as? String ?? "[]"
        case .failure(let error): problem = "\(error)"
        }
    }
    guard spin(40, until: { output != nil || problem != nil }), let json = output,
          let checks = try? JSONDecoder().decode([Check].self, from: Data(json.utf8)), !checks.isEmpty else {
        print("FAIL  \(file) did not finish: \(problem ?? "timeout or empty result")")
        var partial: String?
        web.evaluateJavaScript("JSON.stringify((window.__tempoResults || []).map(r => (r.ok ? 'ok ' : 'FAIL ') + r.name + ' [' + r.detail + ']'))",
                               in: nil, in: contentWorld) { result in partial = (try? result.get()) as? String ?? "?" }
        _ = spin(5, until: { partial != nil })
        print("      reached: \(partial ?? "nothing")")
        exit(1)
    }
    return checks
}

var failed = 0
for (file, contentWorld) in [("unit.js", world), ("remote.js", background), ("cases.js", WKContentWorld.page)] {
    for check in run(file, in: contentWorld) {
        let expected = pageEngine || check.needsPageEngine != true
        let good = check.ok == expected
        if !good { failed += 1 }
        let label = good ? (expected ? "ok   " : "ok   (fails without the page engine, as it should)") : "FAIL "
        print("\(label) \(check.name)\(good && expected ? "" : "  [\(check.detail)]")")
    }
}
print(failed == 0 ? "all checks passed (\(pageEngine ? "page engine" : "standby engine only"))" : "\(failed) check(s) failed")
exit(failed == 0 ? 0 : 1)
