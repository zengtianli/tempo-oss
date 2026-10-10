import SafariServices

/// The extension is plain web code. The one thing that passes through here is the `tempo` command's request
/// for the page in the current tab, and only while the "remote" setting is on: the background page parks a
/// native message, Relay answers it when the command line asks for something. Nothing leaves this Mac.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let profile = (item?.userInfo?[SFExtensionProfileKey] as? UUID)?.uuidString ?? ""
        Relay.shared.receive(message, profile: profile) { reply in
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }
}
