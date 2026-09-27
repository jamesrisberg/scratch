import ScratchKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var model: AppModel
    var expand: () -> Void = {}
    var dismiss: () -> Void = {}

    var body: some View {
        Group {
            if model.isCompact {
                CompactStripView(model: model, expand: expand)
            } else {
                // One pad you type into; the pad list beside it is optional (sidebar.visible).
                HStack(spacing: 0) {
                    if model.sidebarVisible {
                        SidebarView(model: model)
                            .frame(width: 200)
                        Divider().opacity(0.5)
                    }
                    EditorPane(model: model, dismiss: dismiss)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .onDrop(of: [.fileURL, .utf8PlainText, .plainText], isTargeted: $model.isDropTargeted) { providers in
            DropHandler.handle(providers, model: model)
        }
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: model.isCompact ? 20 : 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                    TextField("Search", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let first = model.visiblePads.first { model.selectedID = first.id; model.editor?.focus() } }
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                Button { model.newPad() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain)
                    .help("New pad (⌘N)")
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)

            let pads = model.visiblePads
            if pads.isEmpty {
                Spacer()
                Text(model.searchText.isEmpty ? "No pads yet.\n⌘N or drop text here." : "No matches")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(selection: $model.selectedID) {
                    ForEach(pads) { pad in
                        PadRow(pad: pad, query: model.searchText)
                            .tag(pad.id)
                            .contextMenu {
                                Button(pad.pinned ? "Unpin" : "Pin") { model.togglePin(pad.id) }
                                Button("Copy Pad") { model.selectedID = pad.id; model.copyPad() }
                                Divider()
                                Button("Delete", role: .destructive) { model.delete(pad.id) }
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
    }
}

struct PadRow: View {
    let pad: Pad
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if pad.isInbox {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if pad.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange)
                }
                Text(pad.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if !query.isEmpty, let snippet = PadStore.snippet(pad.body, query: query, width: 40) { return snippet }
        // The first line of content after the title, skipping inbox separators and code fences;
        // for the inbox, the newest entry.
        var lines = pad.body.split(whereSeparator: \.isNewline).map(String.init)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !(t.hasPrefix("--- ") && t.hasSuffix(" ---")) && !t.hasPrefix("```")
            }
        if pad.titleOverride == nil, !lines.isEmpty { lines.removeFirst() }
        let newestFirst = pad.isInbox && pad.body.contains(where: \.isNewline) ? lines.last : lines.first
        let preview = newestFirst.map { Pad.deriveTitle(from: $0) }
        return RelativeTime.string(pad.updatedAt) + (preview.map { " · " + $0 } ?? "")
    }
}

enum RelativeTime {
    static func string(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }
}

// MARK: - Editor pane

struct EditorPane: View {
    @ObservedObject var model: AppModel
    var dismiss: () -> Void = {}
    @State private var padsShown = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ZStack {
                EditorView(model: model)
                if model.selectedPad == nil {
                    Text("Select or create a pad").foregroundStyle(.secondary)
                }
            }
            Divider().opacity(0.4)
            footer
        }
    }

    /// Slim: the sidebar chevron, the pad's title (editable), then Clear, Copy, Transform,
    /// Pin, Pads (when the list is hidden) and dismiss.
    private var header: some View {
        HStack(spacing: 10) {
            iconButton(model.sidebarVisible ? "chevron.left" : "chevron.right",
                       model.sidebarVisible ? "Hide the pad list (⌘⇧L)" : "Show the pad list (⌘⇧L)") { model.toggleSidebar() }
                .font(.system(size: 10, weight: .semibold))
            if let pad = model.selectedPad {
                TitleField(model: model, pad: pad)
            } else {
                Text("Scratch").font(.system(size: 13, weight: .semibold))
            }
            Spacer(minLength: 4)
            if let pad = model.selectedPad {
                iconButton("eraser", "Clear the pad (⌘K)") { model.clear(pad.id); model.editor?.focus() }
                    .disabled(pad.body.isEmpty)
                iconButton("doc.on.doc", "Copy the pad (⌘⇧C)") { model.copyPad() }
                Menu {
                    let groups = Dictionary(grouping: Transform.allCases, by: \.group).sorted { $0.key < $1.key }
                    ForEach(groups, id: \.key) { group in
                        Section {
                            ForEach(group.value) { t in Button(t.title) { model.applyTransform(t) } }
                        }
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Transform the selection, or the whole pad")
                iconButton(pad.pinned ? "pin.fill" : "pin", pad.pinned ? "Unpin" : "Pin") { model.togglePin(pad.id) }
            }
            if !model.sidebarVisible {
                Button { padsShown.toggle() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "list.bullet")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Pads")
                .popover(isPresented: $padsShown, arrowEdge: .bottom) {
                    PadsPopover(model: model) { padsShown = false }
                }
            }
            iconButton("xmark", "Dismiss (Esc)", action: dismiss)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let flash = model.flash {
                Text(flash.text)
                    .foregroundStyle(flash.isError ? Color.red : Color.secondary)
                    .lineLimit(1)
                if let undo = flash.undo {
                    Button("Undo", action: undo).buttonStyle(.link)
                }
            } else if let pad = model.selectedPad {
                Text("Edited \(RelativeTime.string(pad.updatedAt))").foregroundStyle(.tertiary)
            }
            Spacer()
            if let pad = model.selectedPad {
                Text(TextStats(pad.body).summary).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 26)
    }
}

// MARK: - Title

/// The pad's title, edited in place. Committing an empty title (or the first line's) goes back
/// to deriving it from the body.
struct TitleField: View {
    @ObservedObject var model: AppModel
    let pad: Pad
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(Pad.untitled, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .focused($focused)
            .onSubmit { commit(); model.editor?.focus() }
            .onChange(of: focused) { if !focused { commit() } }
            .onAppear { text = pad.title }
            .onChange(of: pad.id) { text = pad.title }
            .onChange(of: pad.title) { if !focused { text = pad.title } }
            .help("Rename the pad")
    }

    private func commit() {
        model.rename(pad.id, to: text)
        text = model.store.pad(pad.id)?.title ?? text
    }
}

// MARK: - Pads popover

/// Switch, create and delete pads while the sidebar is hidden.
struct PadsPopover: View {
    @ObservedObject var model: AppModel
    var close: () -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.newPad(); close() } label: {
                Label("New Pad", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.pads) { pad in row(pad) }
                }
                .padding(4)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 260)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ pad: Pad) -> some View {
        HStack(spacing: 6) {
            PadRow(pad: pad, query: "")
            Spacer(minLength: 0)
            if hovered == pad.id {
                Button { model.delete(pad.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete (Undo in the footer)")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(pad.id == model.selectedID ? Color.accentColor.opacity(0.35) : hovered == pad.id ? Color.white.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? pad.id : (hovered == pad.id ? nil : hovered) }
        .onTapGesture { model.select(pad.id); model.editor?.focus(atEnd: true); close() }
    }
}

// MARK: - Compact

/// The compact representation: one line with the current pad's title and when it last changed.
struct CompactStripView: View {
    @ObservedObject var model: AppModel
    var expand: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 10) {
                Image(systemName: "note.text").foregroundStyle(.secondary)
                Text(model.selectedPad?.title ?? "Scratch")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let pad = model.selectedPad {
                    Text(RelativeTime.string(pad.updatedAt, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text("\(model.pads.count)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Expand")
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: expand)
            .help("Open the pad")
        }
    }
}

// MARK: - Drops

@MainActor
enum DropHandler {
    /// Files become pads (link plus contents when small text); text becomes a new pad.
    static func handle(_ providers: [NSItemProvider], model: AppModel) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            let group = DispatchGroup()
            let lock = NSLock()
            var urls: [URL] = []
            for provider in fileProviders {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                MainActor.assumeIsolated { _ = model.importFiles(urls.sorted { $0.lastPathComponent < $1.lastPathComponent }) }
            }
            return true
        }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { model.importText(text) } }
        }
        return true
    }
}
