import AppKit
import SwiftUI

struct WindowRestorationDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { RestorationDisablingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class RestorationDisablingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isRestorable = false
        }
    }
}
