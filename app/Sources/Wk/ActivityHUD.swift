import AppKit
import SwiftUI
import WkKit

/// A small floating capsule, top-center of the screen (where the palette's search bar just was,
/// so the eye doesn't have to travel), that shows the newest activity while
/// the palette is hidden: "Opening ABC-123 …" with live progress lines, then ✓ / ⚠ with the
/// result. It replaces the visibility the old menu-bar dropdown used to provide, and covers the
/// gap between pressing ↵ and cmux coming forward.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ActivityHUD {
    static let shared = ActivityHUD()

    private var panel: HUDPanel?
    private var store: AppStore?
    private var busyID: UUID?
    private var hideTask: Task<Void, Never>?

    func attach(_ store: AppStore) {
        self.store = store
        observe()
    }

    /// Re-evaluates on every store change (activities are @Observable); PaletteController also
    /// calls refresh() when the palette shows or hides.
    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.activities
        } onChange: {
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
        refresh()
    }

    func refresh() {
        guard let store else { return }
        if PaletteController.shared.isVisible {
            hideTask?.cancel()
            busyID = nil
            dismiss()
            return
        }
        if let busy = store.activities.first(where: { !$0.done }) {
            hideTask?.cancel()
            busyID = busy.id
            present()
        } else if let shown = busyID, let activity = store.activities.first(where: { $0.id == shown }), activity.done {
            // The activity we were showing just finished: keep its result up briefly.
            present()
            hideTask?.cancel()
            let linger: Duration = .seconds(activity.failed ? 4.0 : 1.4)
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: linger)
                guard !Task.isCancelled else { return }
                self?.busyID = nil
                self?.dismiss()
            }
        } else {
            dismiss()
        }
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 72),
                             styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        if let store {
            panel.contentView = NSHostingView(rootView: ActivityHUDView().environment(store))
        }
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 20))
    }
}

/// The capsule itself: spinner + title + latest progress line while running; ✓ / ⚠ + result after.
struct ActivityHUDView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let activity = store.activities.first {
                HStack(spacing: 12) {
                    if !activity.done {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: activity.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(activity.failed ? .orange : .green)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activity.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let line = activity.lines.last {
                            Text(line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(width: 460, alignment: .leading)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.10)))
                .contentShape(Rectangle())
                .onTapGesture { PaletteController.shared.show() }
            }
        }
        .frame(width: 460, height: 72, alignment: .top)
    }
}
