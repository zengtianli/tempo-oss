#if !APP_STORE
import AppKit
import SwiftUI

/// Explicit offscreen acceptance only; never called by normal launches or CLI settings commands.
enum TempoLocalizationAcceptance {
    @MainActor static func run() -> Never {
        guard let path = ProcessInfo.processInfo.environment["TEMPO_L10N_OUT"],
              ProcessInfo.processInfo.environment["TEMPO_STORE"] != nil,
              ProcessInfo.processInfo.environment["TEMPO_BASICS_SUITE"]?.hasPrefix("test.") == true else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        app.applicationIconImage = NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")!)
        let out = URL(fileURLWithPath: path)
        var report: [String: Any] = [:]
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let states: [(String, Bool?, Bool, String?)] = [
                ("main-enabled", true, true, nil),
                ("main-disabled", false, true, nil),
                ("main-unknown", nil, true, nil),
                ("main-recovery", nil, true, String(localized: "Unable to check the extension. Open Safari, then try again.")),
                ("main-unnotarized", false, false, nil)
            ]
            for (name, enabled, notarized, problem) in states {
                let view = NSHostingView(rootView: ContentView(previewEnabled: enabled, previewNotarized: notarized, previewProblem: problem))
                let size = view.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.setContentSize(size)
                view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                try snapshot(view, window: window, to: out.appendingPathComponent(name + ".png"))
                window.close()
            }
            let menu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = NSMenu(); menu.addItem(appItem); app.mainMenu = menu
            let basics = TempoBasics.shared
            basics.install()
            basics.refresh()
            func settingsSnapshot(_ name: String) throws -> [String] {
                let stack = NSStackView(views: basics.groups())
                stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
                stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
                stack.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalToConstant: 520).isActive = true }
                let size = stack.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = stack; window.setContentSize(size)
                stack.layoutSubtreeIfNeeded()
                try snapshot(stack, window: window, to: out.appendingPathComponent(name + ".png"))
                defer { window.close() }
                return strings(stack)
            }
            var texts = try settingsSnapshot("product-settings")
            // Error/recovery state: an invalid speed is rejected and the previous settings are kept.
            basics.speed.stringValue = "bad"; basics.saveSpeed()
            let errorText = basics.message.stringValue
            texts += try settingsSnapshot("product-settings-error")
            basics.refresh()
            // The shared settings window (设置…, ⌘,), built exactly as the menu action builds it, never ordered in.
            var lifecycleChecks: [String: Bool] = [:]
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for (key, value) in try AppLifecycleUI.shared.offscreenSnapshot(to: out.appendingPathComponent("lifecycle-settings-\(label).png"), appearance: appearance) {
                    lifecycleChecks["\(label).\(key)"] = value
                }
            }
            let lifecycleTexts = app.windows.compactMap(\.contentView).flatMap(strings)
            let menuTexts = AppLifecycleUI.menuItems(ownsSettings: true).map(\.title) + (appItem.submenu?.items.map(\.title) ?? [])
            let allTexts = texts + lifecycleTexts + menuTexts + [errorText]
            let remaining = allTexts.filter(hasChinese)
            let catalogURL = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj")!
            let catalog = NSDictionary(contentsOf: catalogURL) as? [String: String] ?? [:]
            let resolved = catalog.keys.sorted().map { String(localized: String.LocalizationValue($0)) }
            let actualLanguage = Bundle.main.preferredLocalizations.first ?? "unknown"
            let expectedLanguage = ProcessInfo.processInfo.environment["TEMPO_L10N_LANGUAGE"] ?? "en"
            let english = actualLanguage == "en"
            let catalogRemaining = english ? resolved.filter(hasChinese) : []
            // Chinese launch must still resolve to Chinese: the catalog and the shared window both.
            let chineseResolves = english || (resolved.contains(where: hasChinese) && lifecycleTexts.contains(where: hasChinese) && hasChinese(errorText))
            let neverVisible = app.windows.allSatisfy { !$0.isVisible && !$0.isKeyWindow }
            report = ["ok": actualLanguage == expectedLanguage && !catalog.isEmpty && neverVisible && chineseResolves
                        && lifecycleChecks.values.allSatisfy { $0 } && !errorText.isEmpty
                        && (!english || (remaining.isEmpty && catalogRemaining.isEmpty)),
                      "language": actualLanguage,
                      "remaining": english ? remaining : [], "catalog_remaining": catalogRemaining,
                      "chinese_resolves": chineseResolves, "error_text": errorText,
                      "settings_strings": texts, "lifecycle_strings": lifecycleTexts, "menu_strings": menuTexts,
                      "lifecycle_checks": lifecycleChecks,
                      "resolved_catalog": resolved, "never_visible_or_key": neverVisible,
                      "activation_prohibited": app.activationPolicy() == .prohibited]
            app.windows.forEach { $0.close() }
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: out.appendingPathComponent("native.json"))
        } catch { fputs("Localization acceptance: \(error)\n", stderr); exit(1) }
        exit(report["ok"] as? Bool == true ? 0 : 1)
    }

    private static func hasChinese(_ text: String) -> Bool {
        // ICU's \p{Han} also matches U+00B7 (the "·" in English status lines); CJK ideographs only.
        text.replacingOccurrences(of: "倍速", with: "").range(of: "[\\u3400-\\u9FFF]", options: .regularExpression) != nil
    }
    private static func strings(_ view: NSView) -> [String] {
        var values: [String] = []
        if let field = view as? NSTextField { values.append(field.stringValue) }
        if let button = view as? NSButton { values.append(button.title) }
        return values + view.subviews.flatMap(strings)
    }
    private static func snapshot(_ view: NSView, window: NSWindow, to url: URL) throws {
        precondition(!window.isVisible && !window.isKeyWindow && NSApp.activationPolicy() == .prohibited)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.windowBackgroundColor.setFill(); view.bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
#endif
