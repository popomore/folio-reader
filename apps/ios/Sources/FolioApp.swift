import Observation
import SwiftUI

@MainActor @Observable
final class ReaderPreferences {
    private let defaults: UserDefaults
    var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    var scale: Double { didSet { defaults.set(scale, forKey: "readingScale") } }
    var serif: Bool { didSet { defaults.set(serif, forKey: "serif") } }
    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: "appearance") ?? "system"
        scale = defaults.object(forKey: "readingScale") as? Double ?? 1
        serif = defaults.bool(forKey: "serif")
    }
}

@main
struct FolioApp: App {
    @State private var library: LibraryStore
    @State private var preferences: ReaderPreferences

    init() {
        var base: URL?
        var defaults = UserDefaults.standard
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["FOLIO_UI_TEST_LIBRARY"],
           UUID(uuidString: test) != nil {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UITests/\(test)")
            defaults = UserDefaults(suiteName: "FolioUITests.\(test)") ?? .standard
        }
        #endif
        _library = State(initialValue: LibraryStore(base: base))
        _preferences = State(initialValue: ReaderPreferences(defaults: defaults))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(preferences)
                .preferredColorScheme(preferences.colorScheme)
        }
    }
}

struct ReadingSettings: View {
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var preferences = preferences
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $preferences.appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .accessibilityIdentifier("appearance-picker")
                }
                Section("Reading") {
                    Picker("Text Size", selection: $preferences.scale) {
                        Text("Small").tag(0.9)
                        Text("Default").tag(1.0)
                        Text("Large").tag(1.15)
                        Text("Extra Large").tag(1.3)
                    }
                    Toggle("Serif Font", isOn: $preferences.serif)
                    Text("Text also follows your device's Dynamic Type setting.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("About Folio") {
                    Text("A reader for local project files.")
                    Text("Folders stay in their original location. Imported files are copied into Folio.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                }
            }
            .navigationTitle("Reading Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(preferences.colorScheme)
    }
}
