import SwiftUI
import AppKit
import RillCore

enum RillTheme {
    static let accent = Color(red: 0.82, green: 0.24, blue: 0.22)
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.08)
    static let mono = Font.system(size: 12, design: .monospaced)
}

extension ConnectionEnvironment {
    var color: Color {
        switch self { case .local: return .green; case .development: return .blue; case .staging: return .orange; case .production: return RillTheme.accent }
    }
}
extension KeyKind {
    var color: Color {
        switch self {
        case .string: return Color(red: 0.22, green: 0.51, blue: 0.43)
        case .hash: return .blue
        case .list: return .purple
        case .set: return .orange
        case .zset: return .indigo
        case .stream: return RillTheme.accent
        case .unknown: return .secondary
        }
    }
}

struct TypeBadge: View {
    let kind: KeyKind
    var body: some View {
        Text(kind.rawValue.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.5).foregroundStyle(kind.color).padding(.horizontal, 6).padding(.vertical, 4)
            .background(kind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
    }
}
struct EnvironmentBadge: View {
    let environment: ConnectionEnvironment
    var body: some View {
        HStack(spacing: 5) { Circle().fill(environment.color).frame(width: 5, height: 5); Text(environment.title) }
            .font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4)
            .background(environment.color.opacity(0.09), in: Capsule())
    }
}
struct RillMark: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26).fill(LinearGradient(colors: [Color(red: 0.95, green: 0.39, blue: 0.29), RillTheme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: size * 0.51, weight: .medium)).foregroundStyle(.white)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
                .frame(width: 80, height: 80).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 22))
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 330)
            actions.padding(.top, 5)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
func byteCount(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .binary) }

struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var editable = true
    var fontSize: CGFloat = 13
    var json = false
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let view = NSTextView(); view.delegate = context.coordinator
        view.isRichText = false; view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false
        view.allowsUndo = true; view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 18, height: 18)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel(editable ? "Redis 值编辑器" : "Redis 值只读视图")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if view.string != text {
            let range = view.selectedRange(); view.string = text
            view.setSelectedRange(NSRange(location: min(range.location, view.string.utf16.count), length: 0))
        }
        view.isEditable = editable; view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.setAccessibilityLabel(editable ? "Redis 值编辑器" : "Redis 值只读视图")
        context.coordinator.highlight(view)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        init(_ parent: CodeTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string; highlight(view)
        }
        private var highlightTask: Task<Void, Never>?
        private var previousSource: String?
        private var previousJSON = false
        func highlight(_ view: NSTextView) {
            let source = view.string, json = parent.json
            guard source != previousSource || json != previousJSON else { return }
            previousSource = source; previousJSON = json; highlightTask?.cancel()
            guard let layout = view.layoutManager else { return }
            let range = NSRange(location: 0, length: source.utf16.count)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            guard json, range.length < 200_000 else { return }
            highlightTask = Task { @MainActor [weak view] in
                let spans = await Task.detached(priority: .userInitiated) { JSONHighlight.spans(source) }.value
                guard !Task.isCancelled, let view, view.string == source, let layout = view.layoutManager else { return }
                for span in spans {
                    let color: NSColor
                    switch span.kind { case .key: color = .systemBlue; case .string: color = .systemGreen; case .literal: color = .systemPurple; case .number: color = .systemOrange }
                    layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: span.range)
                }
            }
        }
        deinit { highlightTask?.cancel() }
    }
}
