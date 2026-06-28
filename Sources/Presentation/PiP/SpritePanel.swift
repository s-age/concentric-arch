import AppKit
import SwiftUI

final class SpritePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = .black
        minSize = NSSize(width: 240, height: 160)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    @MainActor
    static func open<Content: View>(content: @escaping (SpritePanel) -> Content) -> SpritePanel {
        let panel = SpritePanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320))
        let view = content(panel)
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.orderFront(nil)
        return panel
    }
}
