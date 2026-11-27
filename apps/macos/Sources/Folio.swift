import AppKit
import SwiftUI

enum InstanceMode {
    static let isSeparate = CommandLine.arguments.contains("--folio-new-instance")
}

@main
struct Folio: App {
    @NSApplicationDelegateAdaptor(FolioDelegate.self) private var delegate
    @StateObject private var model = ReaderModel()
    @StateObject private var updates = FolioUpdates()
    @StateObject private var settings = SettingsNavigation()
    @FocusedValue(\.quickPreviewActive) private var quickPreviewActive

    private var workspaceFocused: Bool { quickPreviewActive != true }

    var body: some Scene {
        Window("Folio", id: "workspace") {
            WorkspaceSceneContent(delegate: delegate, model: model, updates: updates, settings: settings)
        }
        .defaultSize(width: 1130, height: 760)
        .commands {
            CommandMenu("iCloud") {
                Button("Continue on Another Device") { model.sendActiveToCloud() }
                    .disabled(!model.cloud.available || model.cloud.sharing || model.active == nil ||
                              model.active?.dirty == true || model.active?.cloudReadOnly == true)
                Button("Send Folder with Assets…") { model.sendActiveToCloud(folder: true) }
                    .disabled(!model.cloud.available || model.cloud.sharing || model.active == nil ||
                              model.active?.dirty == true || model.active?.cloudReadOnly == true)
                Divider()
                ForEach(model.cloud.continuing.prefix(20)) { item in
                    Button(item.name) { Task { await model.openCloud(item) } }
                        .disabled(model.cloud.uploading(item))
                }
                Divider()
                Button("Manage Reading Copies") { settings.open(.iCloud) }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    settings.open(.updates)
                    updates.check()
                }
                .disabled(!updates.isConfigured)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.choose() }.keyboardShortcut("o").disabled(!workspaceFocused)
                Button("Add Folders…") { model.choose(foldersOnly: true) }.disabled(!workspaceFocused)
                if workspaceFocused {
                    Button("Close Tab", action: model.closeActive)
                        .keyboardShortcut("w").disabled(model.active == nil && !model.showingGit)
                } else {
                    Button("Close Preview") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.active?.save() }.keyboardShortcut("s").disabled(!workspaceFocused || model.active?.editing != true || model.showingGit)
                Button("Reload from Disk", action: model.reload).keyboardShortcut("r").disabled(!workspaceFocused || model.gitLocation == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Document") { model.active?.finding = true }
                    .keyboardShortcut("f").disabled(!workspaceFocused || model.active?.canFind != true || model.showingGit)
                Button(model.active?.editing == true ? "Return to Reading" : "Edit Source") {
                    if let active = model.active { active.setMode(active.editing ? .reading : .source) }
                }
                .keyboardShortcut("e")
                .disabled(!workspaceFocused || model.active?.canEdit != true || model.showingGit)
            }
            CommandGroup(after: .toolbar) {
                Button("Focus Folder Tree", action: model.focusFolderTree)
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!workspaceFocused)
                Button(model.sidebar ? "Hide Sidebar" : "Show Sidebar") { model.sidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control]).disabled(!workspaceFocused)
                Button(model.inspector ? "Hide Inspector" : "Show Inspector") { model.inspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option]).disabled(!workspaceFocused)
                Button("Focus Reading") {
                    let focus = model.sidebar || model.inspector
                    model.sidebar = !focus
                    model.inspector = false
                }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(!workspaceFocused)
                Button(model.split ? "Merge Panes" : "Split Pane", action: model.toggleSplit)
                    .keyboardShortcut("\\").disabled(!workspaceFocused)
                Button("Next Tab") { model.cycle(1) }.keyboardShortcut(.tab, modifiers: [.control]).disabled(!workspaceFocused)
                Button("Previous Tab") { model.cycle(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(!workspaceFocused)
                Button(model.showingGit ? "Back to Reading" : "Show Git") { model.showingGit.toggle() }
                    .disabled(!workspaceFocused || model.gitLocation == nil)
                Divider()
                Button("Increase Text Size") { model.appearance.size = min(30, model.appearance.size + 1) }.keyboardShortcut("=")
                Button("Decrease Text Size") { model.appearance.size = max(13, model.appearance.size - 1) }.keyboardShortcut("-")
                Button("Reset Text Size") { model.appearance.size = 18 }.keyboardShortcut("0")
            }
        }
        Window("Quick Preview", id: QuickPreviewRequest.windowID) {
            PreviewSceneContent(delegate: delegate, model: model, updates: updates)
                .preferredColorScheme(model.appearance.workspace.colorScheme)
        }
        .defaultSize(width: 680, height: 580)
        .defaultPosition(.center)
        .handlesExternalEvents(matching: [QuickPreviewRequest.route])
        .commandsRemoved()

        Settings {
            ReaderSettings(model: model, updates: updates, navigation: settings)
                .preferredColorScheme(model.appearance.workspace.colorScheme)
        }
    }
}

@MainActor
final class FolioDelegate: NSObject, NSApplicationDelegate {
    weak var model: ReaderModel?
    weak var updates: FolioUpdates?
    var pending: [URL] = []
    var showWorkspace: (([URL]) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let showWorkspace { showWorkspace(files) } else { pending.append(contentsOf: files) }
    }

    func registerWorkspace(model: ReaderModel, openWindow: OpenWindowAction) {
        showWorkspace = { [weak model] urls in
            model?.openURLs(urls)
            openWindow(id: "workspace")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard updates?.allowUpdateTermination() != false else { return .terminateCancel }
        return model?.protectAllDrafts() == false ? .terminateCancel : .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct WorkspaceSceneContent: View {
    let delegate: FolioDelegate
    @ObservedObject var model: ReaderModel
    let updates: FolioUpdates
    let settings: SettingsNavigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ReaderWindow(model: model)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if model.active?.cloudReadOnly == true {
                        Label("iCloud reading copy. Edit the original file to make changes.", systemImage: "icloud")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let notice = model.cloud.notice {
                        HStack {
                            Text(notice).font(.caption)
                            Spacer()
                            Button("Dismiss iCloud Message", systemImage: "xmark") { model.cloud.notice = nil }
                                .labelStyle(.iconOnly).buttonStyle(.plain)
                        }
                    }
                }
                .padding(model.active?.cloudReadOnly == true || model.cloud.notice != nil ? 8 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
            .preferredColorScheme(model.appearance.workspace.colorScheme)
            .frame(minWidth: 660, minHeight: 420)
            .onContinueUserActivity(CloudEnvironment.activityType, perform: model.continueCloudActivity)
            .userActivity(CloudEnvironment.activityType,
                isActive: model.active?.cloudItem.map { model.cloud.canContinue($0) } == true && !model.cloud.testOnly) { activity in
                if let tab = model.active, let item = tab.cloudItem {
                    CloudContinuation.configure(activity, item: item, position: tab.readingPosition,
                        folder: item.storage == .linked ? tab.location.root : nil)
                }
            }
            .task(id: scenePhase) {
                if scenePhase == .active {
                    while !Task.isCancelled {
                        await model.cloud.refresh()
                        do { try await Task.sleep(for: .seconds(30)) } catch { break }
                    }
                } else { await model.cloud.flushPositions() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in
                model.cloud.accountChanged()
                Task { await model.cloud.refresh() }
            }
            .onChange(of: model.cloud.retired) { _, ids in model.retireCloudTabs(ids) }
            .onChange(of: model.cloud.eviction) { _, event in
                if let event { model.retireCloudTabs([event.item], downloadsOnly: true) }
            }
            .onChange(of: model.cloud.review) { _, request in
                guard let request, let item = model.cloud.item(request.item) else { return }
                Task { await model.openCloud(item, localReview: true); openWindow(id: "workspace") }
            }
            .onChange(of: model.cloud.account) { old, new in
                if old != nil, old != new { model.retireCloudTabs([], all: true) }
            }
            .onAppear {
                delegate.model = model
                delegate.updates = updates
                delegate.registerWorkspace(model: model, openWindow: openWindow)
                updates.start(model: model)
                settings.openSettings = openSettings
                model.openURLs(delegate.pending)
                delegate.pending = []
            }
            .background(WindowOwner(model: model) { window in
                settings.openSettings = openSettings
                if !settings.presentQuickLookSetupIfNeeded() {
                    updates.offerUpdateChecks(on: window)
                }
            })
    }
}

private struct PreviewSceneContent: View {
    let delegate: FolioDelegate
    @ObservedObject var model: ReaderModel
    let updates: FolioUpdates
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        QuickPreview(model: model) { url in
            delegate.showWorkspace?([url])
        }
        .onAppear {
            delegate.updates = updates
            delegate.registerWorkspace(model: model, openWindow: openWindow)
            updates.start(model: model)
            if !delegate.pending.isEmpty {
                let files = delegate.pending
                delegate.pending = []
                delegate.showWorkspace?(files)
            }
        }
    }
}

struct WindowOwner: NSViewRepresentable {
    let model: ReaderModel
    let onReady: (NSWindow) -> Void

    func makeNSView(context: Context) -> Owner {
        Owner(model: model, onReady: onReady)
    }

    func updateNSView(_ view: Owner, context: Context) {
        view.onReady = onReady
    }

    @MainActor
    final class Owner: NSView, NSWindowDelegate {
        weak var model: ReaderModel?
        var onReady: (NSWindow) -> Void
        nonisolated(unsafe) weak var previous: (any NSWindowDelegate)?
        private var titleBarMonitor: Any?
        private var titleBarClickFrame: NSRect?

        init(model: ReaderModel, onReady: @escaping (NSWindow) -> Void) {
            self.model = model
            self.onReady = onReady
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let titleBarMonitor {
                NSEvent.removeMonitor(titleBarMonitor)
                self.titleBarMonitor = nil
            }
            titleBarClickFrame = nil
            guard let window else { return }
            titleBarMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                return handleTitleBarClick(event)
            }

            guard window.delegate !== self else { return }
            previous = window.delegate
            window.delegate = self
            window.backgroundColor = NSColor(WorkspaceStyle.surface)
            if InstanceMode.isSeparate { window.isRestorable = false }
            window.tabbingMode = .disallowed
            DispatchQueue.main.async { [weak self, weak window] in
                if let window, window.isKeyWindow { self?.onReady(window) }
            }
        }

        func windowDidBecomeKey(_ notification: Notification) {
            previous?.windowDidBecomeKey?(notification)
            DispatchQueue.main.async { [weak self] in
                if let self, let window, window.isKeyWindow { onReady(window) }
            }
        }

        private func handleTitleBarClick(_ event: NSEvent) -> NSEvent? {
            let clickFrame = titleBarClickFrame
            titleBarClickFrame = nil
            guard let window, event.window === window else { return event }

            if event.type == .leftMouseUp {
                guard let clickFrame else { return event }
                DispatchQueue.main.async { [weak window] in
                    guard let window, window.frame == clickFrame else { return }
                    window.zoom(nil)
                }
                return nil
            }

            let location = event.locationInWindow
            guard event.clickCount == 2,
                  window.attachedSheet == nil, window.styleMask.contains(.resizable),
                  !window.styleMask.contains(.fullScreen),
                  location.y >= window.contentLayoutRect.maxY,
                  let frameView = window.contentView?.superview else { return event }
            let windowButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let controls = windowButtons.compactMap(window.standardWindowButton)
                + (window.toolbar?.visibleItems ?? []).compactMap(\.view)
            if controls.contains(where: { !$0.isHidden && $0.bounds.contains($0.convert(location, from: nil)) }) {
                return event
            }
            let point = frameView.superview?.convert(location, from: nil) ?? location
            guard frameView.hitTest(point)?.mouseDownCanMoveWindow == true else { return event }

            titleBarClickFrame = window.frame
            return nil
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || previous?.responds(to: aSelector) == true
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if previous?.responds(to: aSelector) == true { return previous }
            return super.forwardingTarget(for: aSelector)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            model?.protectAllDrafts() != false && previous?.windowShouldClose?(sender) != false
        }
    }
}
