import UIKit
import UniformTypeIdentifiers

/// Puts words where the person can paste them, on this iPhone only.
///
/// `.localOnly` keeps them off Universal Clipboard, which would otherwise hand
/// every take to every device on the Apple Account: the iPhone's form of the
/// Mac's `.currentHostOnly` rule. `scripts/check-network-surface.sh` rejects
/// the plain setters (`UIPasteboard.general.string = …`) that skip it.
@MainActor
enum Clipboard {
    static func copy(_ text: String, to pasteboard: UIPasteboard = .general) {
        pasteboard.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
    }
}
