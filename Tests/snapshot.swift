import AppKit
import WebKit

// Renders Extension/Resources/popup.html offscreen (with Tests/shim.js standing in for the extension API)
// and writes a PNG, so the popup layout can be looked at without opening Safari.
//
//   snapshot <Extension/Resources> <Tests> <out.png> [--dark] [--open-settings] [--store '{"speed":1.5}']

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: snapshot <resources> <tests> <out.png> [--dark] [--open-settings] [--store JSON]\n".data(using: .utf8)!)
    exit(2)
}
let resources = URL(fileURLWithPath: args[1])
let tests = URL(fileURLWithPath: args[2])
let out = URL(fileURLWithPath: args[3])
let store = args.firstIndex(of: "--store").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "{}"

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)

let config = WKWebViewConfiguration()
let shim = (try? String(contentsOf: tests.appendingPathComponent("shim.js"), encoding: .utf8)) ?? ""
let seed = "document.dispatchEvent(new CustomEvent('tempo-test:set', { detail: \(String(reflecting: store)) }));"
config.userContentController.addUserScript(WKUserScript(source: shim + "\n" + seed, injectionTime: .atDocumentStart, forMainFrameOnly: true))

let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 304, height: 900), configuration: config)
web.appearance = NSApplication.shared.appearance
web.loadFileURL(resources.appendingPathComponent("popup.html"), allowingReadAccessTo: resources)
spin(1.5)

var height: CGFloat = 0
// A page that is never shown does not advance CSS transitions, so they are switched off for the picture.
let prepare = "document.head.insertAdjacentHTML('beforeend', '<style>*,*::after{transition:none!important}</style>');"
    + (args.contains("--open-settings") ? "document.getElementById('more').open = true;" : "") + "document.body.offsetHeight"
web.evaluateJavaScript(prepare) { value, _ in height = CGFloat((value as? NSNumber)?.doubleValue ?? 600) }
spin(3) { height > 0 }
web.frame = NSRect(x: 0, y: 0, width: 304, height: max(height, 100))
spin(0.3)

var finished = false
let snapshot = WKSnapshotConfiguration()
snapshot.rect = web.bounds
web.takeSnapshot(with: snapshot) { image, error in
    defer { finished = true }
    guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("snapshot failed: \(String(describing: error))")
        return
    }
    try? png.write(to: out)
    print("wrote \(out.path) \(Int(image.size.width))x\(Int(image.size.height))")
}
spin(10) { finished }
exit(finished ? 0 : 1)
