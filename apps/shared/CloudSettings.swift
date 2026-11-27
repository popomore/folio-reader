import SwiftUI

struct CloudSettingsPane: View {
    @Bindable var cloud: CloudLibrary

    var body: some View {
        Form {
            Section("iCloud Reading") {
                LabeledContent("Status", value: cloud.available ? (cloud.testOnly ? "Local Test Library" : "Connected") : "Unavailable")
                Text("Continue reading on your iPhone, iPad, and Mac using the same Apple account.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = cloud.error { Text(error).font(.callout).foregroundStyle(.secondary) }
                Button(cloud.refreshing ? "Refreshing…" : "Refresh iCloud Library") { Task { await cloud.refresh() } }
                    .disabled(cloud.refreshing)
                NavigationLink {
                    CloudCopyManager(cloud: cloud)
                } label: { Label("Manage Reading Copies", systemImage: "externaldrive.badge.icloud") }
                    .accessibilityIdentifier("manage-reading-copies")
            }
            Section("Storage") {
                Text("Reading copies stay in iCloud until you delete them. Your original files stay in their original folders.")
                Text("Documents already in your own iCloud folders are opened in place and are not included in copy cleanup.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("iCloud")
        .task { await cloud.refresh() }
    }
}

struct CloudCopyManager: View {
    enum Order: String, CaseIterable { case recent = "Last Read", size = "Size", name = "Name" }
    @Bindable var cloud: CloudLibrary
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var selection: Set<UUID> = []
    @State private var order = Order.recent
    @State private var confirming: [CloudItem] = []
    @State private var showConfirmation = false

    private var sorted: [CloudItem] {
        cloud.copies.sorted {
            switch order {
            case .recent: cloud.lastRead($0) > cloud.lastRead($1)
            case .size: ($0.byteCount ?? -1) > ($1.byteCount ?? -1)
            case .name: $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
    private var selected: [CloudItem] { sorted.filter { selection.contains($0.id) } }
    private var selectedSize: String {
        let known = selected.compactMap(\.byteCount).reduce(Int64(0), +)
        let size = ByteCountFormatter.string(fromByteCount: known, countStyle: .file)
        return selected.contains { $0.byteCount == nil } ? "\(size) known, some sizes unavailable" : size
    }

    var body: some View {
        VStack(spacing: 0) {
            if !cloud.available {
                ScrollView {
                    ContentUnavailableView("iCloud Unavailable", systemImage: "icloud.slash",
                        description: Text(cloud.error ?? "Check your Apple account and iCloud Drive in Settings."))
                }
            } else if sorted.isEmpty {
                ScrollView {
                    ContentUnavailableView("No Reading Copies", systemImage: "icloud",
                        description: Text("Use Continue on Another Device while reading a local file to add a copy."))
                    messages.padding()
                }
            } else {
                List {
                    messages
                    Section {
                        Picker("Sort By", selection: $order) {
                            ForEach(Order.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        HStack {
                            Text(sorted.count == 1 ? "1 copy" : "\(sorted.count) copies").foregroundStyle(.secondary)
                            Spacer()
                            Button(selection.isEmpty ? "Select All" : "Deselect All") {
                                selection = selection.isEmpty ? Set(sorted.filter(cloud.canDelete).map(\.id)) : []
                            }.disabled(sorted.filter(cloud.canDelete).isEmpty)
                        }
                        ForEach(sorted) { item in row(item) }
                    } footer: {
                        Text("Original files and other iCloud documents are kept.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if textSize.isAccessibilitySize {
                        selectionSummary
                        deleteButton
                    }
                }
            }
        }
        .navigationTitle("Reading Copies")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await cloud.refresh() } }
                .disabled(cloud.refreshing)
        }
        .safeAreaInset(edge: .bottom) {
            if !textSize.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        selectionSummary.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 16)
                        deleteButton.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        selectionSummary
                        deleteButton.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }.padding().background(.bar)
            }
        }
        .alert("Delete \(confirming.count) iCloud Reading \(confirming.count == 1 ? "Copy" : "Copies")?",
            isPresented: $showConfirmation) {
            Button("Delete Copies", role: .destructive) {
                let items = confirming
                selection.subtract(items.map(\.id))
                Task { await cloud.delete(items) }
            }
            Button("Cancel", role: .cancel) { confirming = [] }
        } message: {
            Text("These reading copies and included assets will be removed from iCloud and your other devices. Original files will be kept.")
        }
        .onChange(of: cloud.copies) {
            selection.formIntersection(Set(cloud.copies.filter(cloud.canDelete).map(\.id)))
        }
        .task { await cloud.refresh() }
    }

    private func confirm(_ items: [CloudItem]) {
        confirming = items
        showConfirmation = !items.isEmpty
    }

    @ViewBuilder private var messages: some View {
        if let error = cloud.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        if let notice = cloud.notice {
            Text(notice).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("cloud-notice")
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading) {
            Text("\(selected.count) selected").font(.subheadline)
            if !selected.isEmpty { Text(selectedSize).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var deleteButton: some View {
        Button("Delete Selected Copies", role: .destructive) { confirm(selected) }
            .disabled(selected.isEmpty || selected.contains(where: cloud.busy))
            .accessibilityIdentifier("delete-selected-copies")
    }

    @ViewBuilder private func row(_ item: CloudItem) -> some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    selectButton(item)
                    Text(item.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    actions(item)
                }
                details(item)
                size(item)
            }.padding(.vertical, 8)
        } else {
            HStack(alignment: .top, spacing: 12) {
                selectButton(item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    details(item)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    size(item)
                    actions(item)
                }
            }.padding(.vertical, 4)
        }
    }

    private func selectButton(_ item: CloudItem) -> some View {
        Button {
            if !selection.insert(item.id).inserted { selection.remove(item.id) }
        } label: {
            Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3).frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!cloud.canDelete(item))
        .accessibilityLabel("Select \(item.name)")
        .accessibilityValue(selection.contains(item.id) ? "Selected" : "Not selected")
        .accessibilityIdentifier("select-copy-\(item.name)")
    }

    private func details(_ item: CloudItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("From \(item.sourceDevice)").font(.caption).foregroundStyle(.secondary)
            Text(cloud.lastRead(item), style: .date).font(.caption).foregroundStyle(.secondary)
            if item.folderCopy { Text("\(item.fileCount) files, including folder assets").font(.caption).foregroundStyle(.secondary) }
            if cloud.protected(item) { Text("Unsaved draft, review before deleting").font(.caption).foregroundStyle(.secondary) }
            if cloud.uploading(item), cloud.pending(item) == nil { Text("Waiting to publish to iCloud").font(.caption).foregroundStyle(.secondary) }
            if cloud.pending(item) != nil || item.state == .deleting {
                Text("Pending deletion").font(.caption).foregroundStyle(.secondary)
            }
            if let error = cloud.itemErrors[item.id] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func size(_ item: CloudItem) -> some View {
        Text(item.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unavailable")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func actions(_ item: CloudItem) -> some View {
        Menu {
            if cloud.pending(item) != nil || item.state == .deleting {
                Button("Retry Deletion") { Task { await cloud.retryDeletion(item) } }
                if let request = cloud.pending(item), request.phase != .started {
                    Button("Cancel Pending Deletion") { Task { await cloud.cancelDeletion(item) } }
                }
            } else {
                Button("Remove Download") { Task { await cloud.removeDownload(item) } }
                    .disabled(cloud.protected(item) || cloud.uploading(item))
                Button("Delete iCloud Copy", role: .destructive) { confirm([item]) }
                    .disabled(!cloud.canDelete(item))
            }
        } label: {
            Label("Actions for \(item.name)", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        }.disabled(cloud.busy(item))
    }
}
