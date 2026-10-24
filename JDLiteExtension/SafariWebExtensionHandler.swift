import SafariServices

// The extension works entirely in JavaScript and hands links to the app via
// the jdlite:// URL scheme, so the native side has nothing to do.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
