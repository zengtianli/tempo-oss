#if !APP_STORE
import Foundation

/// The mailbox between the `tempo` command and the app extension, one definition for both sides.
///
/// It is a folder inside the extension's own sandbox container. The command line leaves `request.json`
/// there and rings a Darwin notification; the extension, which has a native message from the background
/// page parked (see background.js), answers that message with the request, and writes `reply-<id>.json`
/// when the page's answer comes back. `armed.json` says which extension process is waiting right now.
/// Nothing is sent anywhere else: the notification carries no data, and the files stay in the container.
enum Mailbox {
    static let extensionIdentifier = "cyou.tianli.tempo.extension"

    /// Tests point both sides at a throwaway folder and give the notification a name of their own.
    static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["TEMPO_REMOTE_DIR"] { return URL(fileURLWithPath: override) }
        // Inside the extension NSHomeDirectory() is already its container; from the command line it is spelled out.
        let home = NSHomeDirectory()
        let base = home.contains("/Library/Containers/\(extensionIdentifier)/") || home.hasSuffix("/Library/Containers/\(extensionIdentifier)/Data")
            ? home
            : home + "/Library/Containers/\(extensionIdentifier)/Data"
        return URL(fileURLWithPath: base + "/Library/Application Support/remote")
    }

    static var bell: String { "cyou.tianli.tempo.remote.request" + (ProcessInfo.processInfo.environment["TEMPO_REMOTE_TAG"] ?? "") }

    static var request: URL { folder.appendingPathComponent("request.json") }
    static var armed: URL { folder.appendingPathComponent("armed.json") }
    static func reply(_ id: String) -> URL { folder.appendingPathComponent("reply-\(id).json") }

    /// A request older than this was left by a command that has given up; it is thrown away, not delivered.
    static let requestLifetime: TimeInterval = 10
    /// How long the extension keeps a native message parked before answering it with nothing.
    static let holdTime: TimeInterval = 25

    static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Written whole or not at all: a reader never sees half a file.
    @discardableResult
    static func write(_ object: [String: Any], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
#endif
