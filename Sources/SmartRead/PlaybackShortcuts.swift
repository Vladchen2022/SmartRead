import SwiftUI

enum PlaybackShortcut: CaseIterable {
    case previous, toggle, next, replay, toggleSpeed, markListening

    var hint: String {
        switch self {
        case .previous: "←"
        case .toggle: "空格"
        case .next: "→"
        case .replay: "↓"
        case .toggleSpeed: "↑"
        case .markListening: "M"
        }
    }

    private var key: KeyEquivalent {
        switch self {
        case .previous: .leftArrow
        case .toggle: .space
        case .next: .rightArrow
        case .replay: .downArrow
        case .toggleSpeed: .upArrow
        case .markListening: "m"
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
    var captureMark: (() -> (() -> Void)?)?
    var extraAction: ((NSEvent) -> (() -> Void)?)?

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
        view.captureMark = captureMark
        view.extraAction = extraAction
    }

    final class MonitorView: NSView {
        var action: ((PlaybackShortcut) -> (() -> Void)?)?
        var captureMark: (() -> (() -> Void)?)?
        var extraAction: ((NSEvent) -> (() -> Void)?)?
        private var monitor: Any?
        private var pendingReplay: Task<Void, Never>?
        private var pendingMark: (() -> Void)?
        private var firstDownAt: TimeInterval?
        private static let doubleTapInterval = 0.25

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            cancelReplay()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleKeyDown(event)
            }
        }

        func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, acceptsKeys(in: window) else {
                cancelReplay()
                return event
            }
            let shortcut = PlaybackShortcut(event: event)
            if shortcut == .replay, captureMark != nil {
                if !event.isARepeat { handleDown(at: event.timestamp) }
                return nil
            }
            cancelReplay()
            let perform = shortcut.flatMap { action?($0) } ?? extraAction?(event)
            guard let perform else { return event }
            if !event.isARepeat { perform() }
            return nil
        }

        private func acceptsKeys(in window: NSWindow) -> Bool {
            window.isKeyWindow && window.attachedSheet == nil && NSApp.modalWindow == nil
                && (window.firstResponder as? NSText)?.isEditable != true
        }

        private func handleDown(at time: TimeInterval) {
            if let firstDownAt, (0...Self.doubleTapInterval).contains(time - firstDownAt) {
                let mark = pendingMark
                cancelReplay()
                mark?()
                return
            }
            cancelReplay()
            firstDownAt = time
            pendingMark = captureMark?()
            let play = action?(.replay)
            pendingReplay = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(Self.doubleTapInterval)) }
                catch { return }
                guard let self else { return }
                cancelReplay()
                if let window, acceptsKeys(in: window) { play?() }
            }
        }

        private func cancelReplay() {
            pendingReplay?.cancel()
            pendingReplay = nil
            pendingMark = nil
            firstDownAt = nil
        }

        deinit {
            pendingReplay?.cancel()
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
