import AppKit
import SwiftUI

enum WorkspaceAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct Appearance: Equatable {
    var workspace: WorkspaceAppearance = .system
    var size = 16.0
    var width = 700.0
    var serif = false

    init() {
        let defaults = UserDefaults.standard
        workspace = WorkspaceAppearance(rawValue: defaults.string(forKey: "workspaceAppearance") ?? "") ?? .system
        size = min(30, max(13, defaults.object(forKey: "textSize") as? Double ?? size))
        width = defaults.object(forKey: "readerWidth") as? Double ?? width
        serif = defaults.object(forKey: "serif") as? Bool ?? serif
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(workspace.rawValue, forKey: "workspaceAppearance")
        defaults.set(size, forKey: "textSize")
        defaults.set(width, forKey: "readerWidth")
        defaults.set(serif, forKey: "serif")
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    enum Page: Hashable { case appearance, iCloud, quickLook, updates }

    @Published var page: Page = .appearance
    var openSettings: OpenSettingsAction?
    private var showingQuickLookSetup = false
    private static let quickLookSetupKey = "folioQuickLookSetupSeen"

    func open(_ page: Page) {
        self.page = page
        openSettings?()
    }

    func presentQuickLookSetupIfNeeded() -> Bool {
        if showingQuickLookSetup { return true }
        guard !InstanceMode.isSeparate, openSettings != nil,
              !UserDefaults.standard.bool(forKey: Self.quickLookSetupKey) else { return false }
        showingQuickLookSetup = true
        open(.quickLook)
        return true
    }

    func didDisplayQuickLook() {
        guard !InstanceMode.isSeparate else { return }
        UserDefaults.standard.set(true, forKey: Self.quickLookSetupKey)
        showingQuickLookSetup = false
    }
}

struct ReaderSettings: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var updates: FolioUpdates
    @ObservedObject var navigation: SettingsNavigation
    @State private var themeMessage: String?

    var body: some View {
        TabView(selection: $navigation.page) {
            appearance.tabItem { Label("Appearance", systemImage: "textformat") }.tag(SettingsNavigation.Page.appearance)
            NavigationStack { CloudSettingsPane(cloud: model.cloud) }
                .tabItem { Label("iCloud", systemImage: "icloud") }.tag(SettingsNavigation.Page.iCloud)
            QuickLookSettings(isSelected: navigation.page == .quickLook)
                .tabItem { Label("Quick Look", systemImage: "eye") }.tag(SettingsNavigation.Page.quickLook)
            UpdateSettings(updates: updates)
                .tabItem { Label("Updates", systemImage: "arrow.clockwise") }.tag(SettingsNavigation.Page.updates)
        }
        .frame(width: 580, height: 500)
        .onChange(of: navigation.page, initial: true) { _, page in
            if page == .quickLook { navigation.didDisplayQuickLook() }
        }
    }

    private var appearance: some View {
        Form {
            Section("Workspace") {
                Picker("Appearance", selection: $model.appearance.workspace) {
                    ForEach(WorkspaceAppearance.allCases) { mode in Text(mode.rawValue.capitalized).tag(mode) }
                }
            }
            Section("Reading") {
                Picker("Typeface", selection: $model.appearance.serif) {
                    Text("Serif").tag(true)
                    Text("Sans Serif").tag(false)
                }
                Stepper("Text size · \(Int(model.appearance.size)) pt", value: $model.appearance.size, in: 13...30)
                Picker("Reading width", selection: $model.appearance.width) {
                    Text("Narrow").tag(570.0)
                    Text("Standard").tag(700.0)
                    Text("Wide").tag(920.0)
                }
            }
            Section("Themes") {
                HStack {
                    Button("Open Theme Folder", action: openThemeFolder)
                    Button("Reload Themes") {
                        ThemeStore.shared.reload()
                        themeMessage = ThemeStore.shared.problems.isEmpty ? "Themes reloaded." : nil
                    }
                }
                Text("Edit \(ThemeMode.light.filename) or \(ThemeMode.dark.filename), then reload. Finder uses the bundled themes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let themeMessage { Text(themeMessage).font(.callout) }
                ForEach(ThemeStore.shared.problems, id: \.self) { problem in
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func openThemeFolder() {
        let themes = ThemeStore.shared
        do {
            try themes.prepareDirectory()
            themeMessage = NSWorkspace.shared.open(themes.directory) ? nil : "Could not open the theme folder."
        } catch {
            themeMessage = error.localizedDescription
        }
    }
}


private struct UpdateSettings: View {
    @ObservedObject var updates: FolioUpdates
    @State private var githubToken = ""

    var body: some View {
        Form {
            if updates.isConfigured, let repository = updates.privateRepository {
                Section("GitHub Access") {
                    LabeledContent("Repository", value: repository)
                    SecureField("GitHub access token", text: $githubToken)
                    HStack {
                        Button("Save Token") {
                            updates.savePrivateCredential(githubToken)
                            githubToken = ""
                        }
                        .disabled(githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if updates.hasPrivateCredential {
                            Button("Remove Token") { updates.savePrivateCredential("") }
                        }
                    }
                    .disabled(!updates.canEditPrivateCredential)
                    Text("Use a read-only token with Contents access to this repository. Folio saves it in the macOS Keychain.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let releases = updates.releasesURL { Link("Open Releases", destination: releases) }
                }
            }
            Section("Software Update") {
                LabeledContent("Installed version", value: updates.currentVersion)
                if updates.isConfigured {
                    TimelineView(.periodic(from: .now, by: 0.4)) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(updates.status)
                            if let progress = updates.downloadProgress {
                                ProgressView(value: progress)
                            } else if updates.isWorking {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    if let version = updates.version {
                        LabeledContent("Available version", value: version)
                        ScrollView {
                            Text(updates.notes).frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 100)
                        .accessibilityLabel("Release Notes")
                    }
                    HStack {
                        Button(updates.lastCheckFailed ? "Retry Check" : "Check for Updates", action: updates.check)
                            .disabled(!updates.canCheck)
                        if updates.canDownload { Button("Download", action: updates.download) }
                        if updates.canInstall { Button("Install and Restart", action: updates.install) }
                        if updates.canDefer { Button("Install Later", action: updates.deferInstallation) }
                        if updates.canCancel { Button("Cancel", action: updates.cancel) }
                    }
                } else if InstanceMode.isSeparate {
                    Text("Use the main Folio instance to check for updates.").foregroundStyle(.secondary)
                } else {
                    Text("This preview is updated by installing a new preview build.").foregroundStyle(.secondary)
                }
            }
            if updates.isConfigured {
                Section("Automatic Updates") {
                    Toggle("Check every 24 hours", isOn: Binding(get: { updates.automaticChecks }, set: updates.setAutomaticChecks))
                    Toggle("Download available updates", isOn: $updates.automaticDownloads)
                    Toggle("Install and restart when Folio is idle", isOn: $updates.automaticInstalls)
                    Text("Automatic download applies to scheduled checks. Installation waits for edits, file opening, and media playback.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
