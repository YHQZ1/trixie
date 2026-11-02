import AppKit
import SwiftUI

/// Hosts the pet and lets mouse clicks fall through to the apps underneath,
/// except on the creature itself (so you can still drag it around).
final class PetHostingView: NSHostingView<PetView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let u = PetView.unit
        let oy = (bounds.height - 30 * u) / 2 + 10 * u
        let top = isFlipped ? oy - 2 * u : bounds.height - (oy + 20 * u)
        let area = NSRect(x: bounds.midX - 12 * u, y: top, width: 24 * u, height: 22 * u)
        return area.contains(local) ? self : nil
    }
}

/// The transparent, always-on-top window that holds the pet.
@MainActor
final class PetWindowController: NSObject, NSWindowDelegate {
    let model = PetModel()
    private let panel: NSPanel
    private var lookTimer: Timer?
    private(set) var isShown = false
    private let positionKey = "petWindowOrigin"

    override init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PetView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = PetHostingView(rootView: PetView(model: model))
        panel.delegate = self
        placeWindow()
    }

    func show() {
        if isShown { return }
        isShown = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        model.hop()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        lookTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateGaze() }
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        lookTimer?.invalidate(); lookTimer = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.isShown == false { self?.panel.orderOut(nil) } }
        })
    }

    // The eyes follow the cursor, but only a little: left, right, up, down or straight ahead.
    private func updateGaze() {
        let mouse = NSEvent.mouseLocation
        let centre = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let dx = mouse.x - centre.x, dy = mouse.y - centre.y
        model.lookX = dx > 100 ? 1 : (dx < -100 ? -1 : 0)
        model.lookY = dy > 100 ? -1 : (dy < -100 ? 1 : 0)
    }

    // MARK: - Remembering where you left it

    private func placeWindow() {
        if let saved = UserDefaults.standard.string(forKey: positionKey) {
            let origin = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -50, dy: -50).contains(origin) }) {
                panel.setFrameOrigin(origin); return
            }
        }
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.maxX - PetView.size.width - 24, y: area.minY + 8))
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: positionKey)
    }
}

/// The little icon in the menu bar, with "Show" and "Quit".
@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onShow: () -> Void
    private let onQuit: () -> Void

    init(onShow: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onShow = onShow; self.onQuit = onQuit
        super.init()
        item.button?.image = Self.icon()
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Trixie", action: #selector(showPet), keyEquivalent: "")
        show.target = self
        let quit = NSMenuItem(title: "Quit Trixie", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(show); menu.addItem(.separator()); menu.addItem(quit)
        item.menu = menu
    }

    @objc private func showPet() { onShow() }
    @objc private func quitApp() { onQuit() }

    /// A tiny pixel version of the pet, drawn as a template so it fits light and dark menu bars.
    private static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            for r in [NSRect(x: 4, y: 3, width: 10, height: 8), NSRect(x: 1, y: 6, width: 3, height: 3),
                      NSRect(x: 14, y: 6, width: 3, height: 3), NSRect(x: 4, y: 11, width: 2, height: 3),
                      NSRect(x: 8, y: 11, width: 2, height: 3), NSRect(x: 12, y: 11, width: 2, height: 3)] {
                r.fill()
            }
            NSGraphicsContext.current?.compositingOperation = .clear
            NSRect(x: 6, y: 5, width: 2, height: 3).fill()
            NSRect(x: 10, y: 5, width: 2, height: 3).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
