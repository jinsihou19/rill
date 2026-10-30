import SwiftUI
import AppKit

// SwiftUI may prepare offscreen rows; the native clip view determines actual visibility.
struct RowVisibility: NSViewRepresentable {
    let identity: String
    let changed: (Bool, UUID) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.configure(identity, changed: changed) }

    final class Probe: NSView {
        private weak var clip: NSClipView?
        private var observer: NSObjectProtocol?
        private var identity = ""
        private let observerID = UUID()
        private var changed: ((Bool, UUID) -> Void)?
        private var last: Bool?
        func configure(_ identity: String, changed: @escaping (Bool, UUID) -> Void) {
            if self.identity != identity {
                if last == true, let old = self.changed { let id = observerID; DispatchQueue.main.async { old(false, id) } }
                self.identity = identity; last = nil
            }
            self.changed = changed; checkVisibility()
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); checkVisibility() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); checkVisibility() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); checkVisibility() }
        override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(point); checkVisibility() }
        override func layout() { super.layout(); checkVisibility() }
        private func checkVisibility() {
            let current = enclosingScrollView?.contentView
            if current !== clip {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                clip = current; current?.postsBoundsChangedNotifications = true
                if let current {
                    observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: current, queue: .main) { [weak self] _ in self?.checkVisibility() }
                }
            }
            let visible = window != nil && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
            guard visible != last else { return }
            last = visible
            if let changed { let id = observerID; DispatchQueue.main.async { changed(visible, id) } }
        }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if last == true, let changed { let id = observerID; DispatchQueue.main.async { changed(false, id) } }
        }
    }
}
