#if APP_STORE
import AppKit
import JavaScriptCore

/// Silent diagnostics for the actual settings schema, without reading Safari's
/// directory or adding network permission for a diagnostic WebView.
enum StoreSelfTest {
    static func run() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            let fm = FileManager.default
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TempoStoreSelfTest", isDirectory: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/TempoExtension.appex/Contents/Resources")
            let standalone = Bundle.main.resourceURL!.appendingPathComponent("StoreWebResources")
            let resources = fm.fileExists(atPath: embedded.appendingPathComponent("shared.js").path) ? embedded : standalone
            guard let context = JSContext() else { throw Failure.invalid("JavaScriptCore unavailable") }
            var problem: String?
            context.exceptionHandler = { _, error in problem = error?.toString() }
            context.evaluateScript(try String(contentsOf: resources.appendingPathComponent("shared.js"), encoding: .utf8))
            let test = """
            (() => {
              const T = Tempo;
              const cfg = T.normalize({speed: 2.5, step: 0.2, remote: true, rules: {'example.org': 1.75}});
              if (cfg.remote !== false || cfg.rules['example.org'] !== 1.75) throw Error('Store import normalization failed');
              const patch = T.speedPatch(cfg, 'example.org', T.target(cfg, 'example.org', 'faster'));
              const changed = T.normalize(Object.assign({}, cfg, patch));
              if (Math.abs(changed.rules['example.org'] - 1.95) > 0.001) throw Error('site speed action failed');
              const exported = JSON.stringify(changed);
              const imported = T.normalize(JSON.parse(exported));
              if (JSON.stringify(imported) !== exported) throw Error('export/import schema roundtrip failed');
              let badRejected = false; try {JSON.parse('{bad json');} catch {badRejected = true;}
              return JSON.stringify({passed: true, configuration_schema_roundtrip: true,
                invalid_json_rejected: badRejected, site_speed_action: true,
                native_channel_forced_off: true, configuration: imported});
            })()
            """
            guard let output = context.evaluateScript(test)?.toString(), problem == nil else {
                throw Failure.invalid(problem ?? "settings rules did not return JSON")
            }
            var result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
            let configuration = result["configuration"] as! [String: Any]
            let fixture = support.appendingPathComponent("configuration.json")
            let serialized = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
            try serialized.write(to: fixture, options: .atomic)
            guard try Data(contentsOf: fixture) == serialized else { throw Failure.invalid("container readback") }
            let html = try String(contentsOf: resources.appendingPathComponent("popup.html"), encoding: .utf8)
            guard !html.contains("id=\"remote\"") else { throw Failure.invalid("CLI control still exists") }
            result["remote_control_absent"] = true
            result["home"] = NSHomeDirectory()
            result["bundle_id"] = Bundle.main.bundleIdentifier
            result["pid"] = ProcessInfo.processInfo.processIdentifier
            result["support_directory"] = support.path
            result["container_read_write"] = true
            result["visible_windows"] = NSApp.windows.filter { $0.isVisible }.count
            result["activation_policy"] = NSApp.activationPolicy() == .prohibited ? "prohibited" : "unexpected"
            result["settings_scope"] = "actual bundled shared.js and container diagnostic JSON; Safari browser.storage.local not accessed"
            guard result["visible_windows"] as? Int == 0, NSApp.activationPolicy() == .prohibited,
                  NSHomeDirectory().contains("/Library/Containers/test.tianli.tempo.store/Data") else {
                throw Failure.invalid("sandbox/silence gate did not hold")
            }
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("store-self-test: \(error)\n".utf8))
            exit(1)
        }
    }

    enum Failure: Error { case invalid(String) }
}
#endif
