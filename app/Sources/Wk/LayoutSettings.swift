import SwiftUI
import WkKit

/// Settings → Layout: which panes a new cmux workspace gets and how they are arranged.
struct LayoutSettings: View {
    @Binding var draft: WkConfig

    var body: some View {
        Form {
            Section {
                LayoutEditor(layout: Binding(
                    get: { draft.layout ?? .standard },
                    set: { draft.layout = $0 == .standard ? nil : $0 }))
                Text("Applies to workspaces opened from now on; open ones keep their panes. ⌘↵ always opens a single Claude pane. A repo can have its own layout under Repos.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Layout").font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary)
                    Text("The panes wk opens in cmux when you press ↵ on a task.").font(.callout).foregroundStyle(.secondary)
                }
                .textCase(nil)
                .padding(.bottom, 8)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A drawing of a layout: one box per pane, in place. With `titles`, each box is labeled.
struct LayoutDiagram: View {
    let layout: LayoutConfig
    var titles = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let gap: CGFloat = titles ? 4 : 2
            if layout.arrange == "tabs" && layout.panes.count > 1 {
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        ForEach(Array(layout.panes.enumerated()), id: \.offset) { index, pane in
                            box(index == 0)
                                .overlay { if titles { Text(pane.title).font(.system(size: 11, weight: .medium)).lineLimit(1).padding(.horizontal, 4) } }
                                .frame(height: titles ? 24 : max(4, size.height * 0.22))
                        }
                    }
                    box(true)
                }
            } else {
                ForEach(Array(layout.frames().enumerated()), id: \.offset) { index, frame in
                    box(index == 0)
                        .overlay {
                            if titles, layout.panes.indices.contains(index) {
                                Text(layout.panes[index].title).font(.system(size: 12, weight: .medium)).lineLimit(1).padding(.horizontal, 4)
                            }
                        }
                        .frame(width: max(1, frame.width * size.width - gap), height: max(1, frame.height * size.height - gap))
                        .position(x: frame.midX * size.width, y: frame.midY * size.height)
                }
            }
        }
    }

    private func box(_ first: Bool) -> some View {
        RoundedRectangle(cornerRadius: titles ? 6 : 2.5)
            .fill(first ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: titles ? 6 : 2.5).strokeBorder(.white.opacity(0.18)))
    }
}

/// Edits one layout: arrangement tiles, a labeled preview, and the list of panes.
struct LayoutEditor: View {
    @Binding var layout: LayoutConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Arrangement")
            HStack(spacing: 8) {
                ForEach(LayoutConfig.arrangements, id: \.id) { item in
                    Button { layout.arrange = item.id } label: {
                        VStack(spacing: 5) {
                            LayoutDiagram(layout: LayoutConfig(arrange: item.id, mainSize: layout.mainSize, panes: layout.panes))
                                .frame(width: 62, height: 40)
                            Text(item.label).font(.system(size: 11))
                        }
                        .padding(6)
                        .background(layout.arrange == item.id ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(layout.arrange == item.id ? Color.accentColor : .white.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
            LayoutDiagram(layout: layout, titles: true)
                .frame(height: 130)
                .padding(8)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        }
        if layout.usesMainSize {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Size of the main pane") {
                    Text("\(layout.mainSize ?? 60)%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(layout.mainSize ?? 60) }, set: { layout.mainSize = Int(($0 / 5).rounded()) * 5 }), in: 30...80)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Panes").padding(.bottom, 2)
            ForEach(Array(layout.panes.enumerated()), id: \.offset) { index, _ in
                paneRow(index)
            }
            HStack {
                Button { layout.panes.append(PaneConfig(kind: "shell")) } label: { Label("Add pane", systemImage: "plus") }
                    .disabled(layout.panes.count >= LayoutConfig.maxPanes)
                Spacer()
                Button("Reset to Claude, server and git") { layout = .standard }
                    .disabled(layout == .standard)
            }
            .padding(.top, 4)
            Text("The first pane is the main one. New worktrees run their install in the Setup pane if there is one, otherwise ahead of the server.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func paneRow(_ index: Int) -> some View {
        let pane = layout.panes[index]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("\(index + 1)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                Picker("", selection: Binding(get: { pane.kind }, set: { layout.panes[index].kind = $0 })) {
                    ForEach(PaneConfig.kinds, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden().frame(width: 118)
                TextField("", text: Binding(get: { pane.name ?? "" }, set: { layout.panes[index].name = $0.isEmpty ? nil : $0 }),
                          prompt: Text("Title: \(PaneConfig(kind: pane.kind, command: pane.command).title)"))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 150)
                if pane.kind == "command" {
                    TextField("", text: Binding(get: { pane.command ?? "" }, set: { layout.panes[index].command = $0.isEmpty ? nil : $0 }),
                              prompt: Text("e.g. lazygit, git status, tail -f log/dev.log"))
                        .labelsHidden().textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                } else {
                    Spacer(minLength: 0)
                }
                Button { layout.panes.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0).help("Move up")
                Button { layout.panes.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == layout.panes.count - 1).help("Move down")
                Button { layout.panes.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    .disabled(layout.panes.count == 1).help("Remove this pane")
            }
            .buttonStyle(.borderless)
            Text(PaneConfig.kinds.first { $0.id == pane.kind }?.about ?? "")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 22)
        }
    }
}
