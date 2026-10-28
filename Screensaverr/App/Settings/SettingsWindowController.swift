import AppKit
import SwiftUI

/// Builds the Options sheet shown by System Settings.
@MainActor
final class SettingsWindowController: NSObject {
    private var window: NSWindow?

    /// A fresh window each time, so it always reflects the saved settings.
    func makeWindow() -> NSWindow {
        let loaded = SettingsStore.loadReportingProblems()
        let model = SettingsViewModel(settings: loaded.settings, problem: loaded.problem)
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = EditableTextWindow(contentViewController: hosting)
        window.title = "Screensaverr"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 720))
        model.onClose = { [weak self, weak window] in
            guard let window else { return }
            self?.close(window)
        }
        self.window = window
        return window
    }

    private func close(_ window: NSWindow) {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            NSApplication.shared.endSheet(window)
            window.orderOut(nil)
        }
        if self.window === window { self.window = nil }
    }
}

/// The screen-saver host has no Edit menu, so ⌘V/⌘C/⌘X/⌘A/⌘Z never reach text fields.
/// Route those shortcuts to the first responder ourselves — essential for pasting API keys.
final class EditableTextWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            let shift = flags.contains(.shift)
            var action: Selector?
            switch key {
            case "x" where !shift: action = #selector(NSText.cut(_:))
            case "c" where !shift: action = #selector(NSText.copy(_:))
            case "v" where !shift: action = #selector(NSText.paste(_:))
            case "a" where !shift: action = #selector(NSText.selectAll(_:))
            case "z": action = shift ? Selector(("redo:")) : Selector(("undo:"))
            default: action = nil
            }
            if let action, NSApplication.shared.sendAction(action, to: nil, from: self) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
