import Foundation

// Stands in for Safari in Tests/cli.sh. The app extension's half of the mailbox is the real one
// (Extension/Relay.swift); the background page is played by this loop, which parks a message, and answers
// each request the command line leaves from a table: $TEMPO_REMOTE_DIR/answers.json, action -> reply.
// An action missing from the table gets no reply at all, which is how a page that never answers looks.
//
//   TEMPO_REMOTE_DIR=<folder> TEMPO_REMOTE_TAG=<suffix> build/tests/tempo-relay
//
// (Not named relay.swift: next to Extension/Relay.swift the two object files would share a name on a
// file system that ignores case.)

@main
enum Driver {
    static func park(_ done: [String: Any]?) {
        var message: [String: Any] = ["t": "next"]
        if let done { message["done"] = done }
        Relay.shared.receive(message, profile: "") { answer in
            guard answer["t"] as? String == "cmd", let id = answer["id"] as? String, let action = answer["action"] as? String,
                  let reply = Mailbox.read(Mailbox.folder.appendingPathComponent("answers.json"))?[action] as? [String: Any] else {
                return park(nil)
            }
            park(["id": id, "reply": reply])
        }
    }

    static func main() {
        park(nil)
        dispatchMain()
    }
}
