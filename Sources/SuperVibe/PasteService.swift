import Cocoa

enum PasteService {

    /// Copy text to clipboard and simulate Cmd+V to paste.
    static func paste(_ text: String, pressEnter: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)

        // Cmd+V down
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        // Cmd+V up
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }

        if pressEnter {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) {
                    enterDown.post(tap: .cghidEventTap)
                }
                if let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) {
                    enterUp.post(tap: .cghidEventTap)
                }
            }
        }
    }
}
