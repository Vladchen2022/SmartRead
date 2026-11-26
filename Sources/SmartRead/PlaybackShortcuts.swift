import SwiftUI

enum PlaybackShortcut: CaseIterable {
    case previous, toggle, next, replay

    var hint: String {
        switch self {
        case .previous: "←"
        case .toggle: "空格"
        case .next: "→"
        case .replay: "↓"
        }
    }

    private var key: KeyEquivalent {
        switch self {
        case .previous: .leftArrow
        case .toggle: .space
        case .next: .rightArrow
        case .replay: .downArrow
        }
    }

    init?(event: NSEvent) {
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(modifiers).isEmpty,
              let character = event.charactersIgnoringModifiers?.lowercased(),
              let shortcut = Self.allCases.first(where: { String($0.key.character) == character }) else { return nil }
        self = shortcut
    }
}

struct PlaybackShortcutMonitor: NSViewRepresentable {
    let action: (PlaybackShortcut) -> (() -> Void)?
    var extraAction: ((NSEvent) -> (() -> Void)?)?

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
        view.extraAction = extraAction
    }

    final class MonitorView: NSView {
        var action: ((PlaybackShortcut) -> (() -> Void)?)?
        var extraAction: ((NSEvent) -> (() -> Void)?)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      (window.firstResponder as? NSText)?.isEditable != true else { return event }
                let perform = PlaybackShortcut(event: event).flatMap { self.action?($0) } ?? self.extraAction?(event)
                guard let perform else { return event }
                if !event.isARepeat { perform() }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
