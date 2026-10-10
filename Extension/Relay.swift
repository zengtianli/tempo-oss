import Foundation
import notify

/// The extension's half of the mailbox (Shared/Mailbox.swift). The background page keeps one native message
/// parked here per Safari profile; it is answered when the command line leaves a request, when the page says
/// it is done listening, or after Mailbox.holdTime with nothing. No request, no work: this object only
/// reacts to messages from the page and to the command line's notification.
final class Relay {
    static let shared = Relay()

    typealias Answer = ([String: Any]) -> Void
    private struct Parked {
        let serial: Int
        let answer: Answer
    }

    private let queue = DispatchQueue(label: "cyou.tianli.tempo.relay")
    private var parked: [String: Parked] = [:]   // Safari profile ("" = the default one) -> the message waiting
    private var serial = 0
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    /// A native message from the background page: `next` (park me; `done` may carry the reply to the last
    /// request), `done` (just the reply), `bye` (nobody is listening any more).
    func receive(_ message: [String: Any], profile: String, answer: @escaping Answer) {
        queue.async {
            // The reply to the last request is written after this process has said it is listening again,
            // so a command that reads the reply and asks at once for something else finds the mailbox armed.
            func writeReply() {
                guard let done = message["done"] as? [String: Any], let id = done["id"] as? String, Relay.plain(id) else { return }
                Mailbox.write(["id": id, "reply": done["reply"] ?? NSNull()], to: Mailbox.reply(id))
            }
            switch message["t"] as? String {
            case "next":
                self.release(profile)
                self.listen()
                if let request = self.pending(for: profile) {
                    try? FileManager.default.removeItem(at: Mailbox.request)
                    self.arm(adding: profile)
                    writeReply()
                    answer(request)
                    return
                }
                self.serial += 1
                let mine = self.serial
                self.parked[profile] = Parked(serial: mine, answer: answer)
                self.arm()
                writeReply()
                self.queue.asyncAfter(deadline: .now() + Mailbox.holdTime) {
                    guard self.parked[profile]?.serial == mine else { return }
                    self.release(profile)   // the page parks the next one; armed.json stays until it says bye
                }
            case "bye":
                writeReply()
                self.release(profile)
                if self.parked.isEmpty { try? FileManager.default.removeItem(at: Mailbox.armed) } else { self.arm() }
                answer(["t": "idle"])
            default:
                writeReply()
                answer(["t": "idle"])
            }
        }
    }

    private static func plain(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// Answers a parked message with nothing, so the page can park the next one (or stop).
    private func release(_ profile: String) {
        parked.removeValue(forKey: profile)?.answer(["t": "idle"])
    }

    /// The request the command line left, if it is fresh and meant for this profile.
    private func pending(for profile: String) -> [String: Any]? {
        guard let request = Mailbox.read(Mailbox.request), let id = request["id"] as? String, Relay.plain(id),
              let action = request["action"] as? String else { return nil }
        let age = Date().timeIntervalSince1970 - (request["at"] as? Double ?? 0)
        guard age >= -2, age <= Mailbox.requestLifetime else {
            try? FileManager.default.removeItem(at: Mailbox.request)
            return nil
        }
        let wanted = request["profile"] as? String ?? ""
        guard wanted.isEmpty || wanted.caseInsensitiveCompare(profile) == .orderedSame
                || (wanted == "Default" && profile.isEmpty) else { return nil }
        return ["t": "cmd", "id": id, "action": action]
    }

    private func deliver() {
        for profile in parked.keys.sorted() {   // "" sorts first: the default profile answers when none is named
            guard let request = pending(for: profile), let waiting = parked.removeValue(forKey: profile) else { continue }
            try? FileManager.default.removeItem(at: Mailbox.request)
            waiting.answer(request)
            return
        }
    }

    private func listen() {
        sweep()
        guard token == NOTIFY_TOKEN_INVALID else { return }
        try? FileManager.default.createDirectory(at: Mailbox.folder, withIntermediateDirectories: true)
        notify_register_dispatch(Mailbox.bell, &token, queue) { [weak self] _ in self?.deliver() }
    }

    /// A reply nobody collected (the command that asked was stopped) is removed after a minute.
    private func sweep() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Mailbox.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix("reply-") {
            let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(written) > 60 { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Says which process is listening and since when, so the command line knows at once whether anybody
    /// would hear it. Rewritten each time a message is parked; removed when the page says bye. A file left
    /// behind by a process that is gone, or not refreshed for longer than a hold, counts as not listening.
    private func arm(adding profile: String? = nil) {
        var profiles = Set(parked.keys)
        if let profile { profiles.insert(profile) }
        Mailbox.write(["pid": Int(getpid()), "at": Date().timeIntervalSince1970, "profiles": profiles.sorted()], to: Mailbox.armed)
    }
}
