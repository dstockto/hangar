import AppKit

/// An ordinary Hangar window, with one rule the panel already had: Command-Q
/// closes it and never quits the app.
///
/// Hangar lives in the menu bar. Every window it opens is something you finish
/// with and put down, so the reflex that closes a document here would otherwise
/// take the whole app out of the menu bar, and the only sign of that is the
/// glyph quietly disappearing. Quitting stays an explicit choice, from the
/// menubar item that says so.
final class HangarWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if HangarPanel.isDismissKey(event) {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
