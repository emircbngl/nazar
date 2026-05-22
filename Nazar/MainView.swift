import SwiftUI

// MARK: - Design tokens
// Single source of truth keeps the whole UI on one rhythm. Spacing follows a
// 4-pt grid; type uses two sizes and two weights only.
private enum D {
    static let pad: CGFloat = 20         // outer / between sections
    static let gap: CGFloat = 12         // inside section
    static let rowV: CGFloat = 7         // row vertical padding
    static let hair: CGFloat = 0.5       // divider thickness

    static let title = Font.system(size: 13, weight: .semibold)
    static let body  = Font.system(size: 13, weight: .regular)
    static let meta  = Font.system(size: 11, weight: .regular)
    static let label = Font.system(size: 10, weight: .medium).smallCaps()
    static let mono  = Font.system(size: 12, weight: .regular).monospacedDigit()
}

struct MainView: View {
    @StateObject private var viewModel = NazarViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: D.pad) {
                    disk
                    apps
                    updates
                }
                .padding(D.pad)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 420, height: 580)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            viewModel.refreshRunningApps()
            viewModel.calculateDiskUsage()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nazar")
                    .font(.system(size: 16, weight: .semibold, design: .default))
                    .tracking(0.5)
                Spacer()
                Text(viewModel.isOptimizing ? "WORKING" : "IDLE")
                    .font(D.label)
                    .foregroundStyle(viewModel.isOptimizing ? .primary : .secondary)
            }
            .padding(.horizontal, D.pad)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: D.hair)
        }
    }

    // MARK: - Disk

    private var disk: some View {
        VStack(alignment: .leading, spacing: D.gap) {
            sectionLabel("DISK")

            if let usage = viewModel.diskUsage {
                HStack(alignment: .firstTextBaseline) {
                    Text(usage.usedFormatted)
                        .font(.system(size: 22, weight: .regular).monospacedDigit())
                    Text("/ \(usage.freeFormatted) free")
                        .font(D.body)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(usage.usedRatio * 100))%")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(usage.usedRatio > 0.9 ? .primary : .secondary)
                }

                // Single flat bar — no gradient, no rounded fluff
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.08))
                        Rectangle()
                            .fill(Color.primary.opacity(usage.usedRatio > 0.9 ? 0.85 : 0.65))
                            .frame(width: max(2, geo.size.width * usage.usedRatio))
                    }
                }
                .frame(height: 3)
                .accessibilityLabel("Disk usage")
                .accessibilityValue("\(Int(usage.usedRatio * 100))% used")
            }

            VStack(spacing: 0) {
                ForEach(Array(viewModel.cleanableItems.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { hairline }
                    DiskRow(item: item, viewModel: viewModel)
                }
            }

            HStack(spacing: 8) {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.addCustomFolder(name: url.lastPathComponent, path: url.path)
                    }
                } label: {
                    Text("Add Folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    viewModel.optimizeDisk()
                } label: {
                    Text(viewModel.isOptimizing ? "Cleaning…" : "Clean")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(viewModel.selectedItems.isEmpty || viewModel.isOptimizing)
            }

            if viewModel.isOptimizing {
                ProgressView(value: viewModel.optimizationProgress)
                    .progressViewStyle(.linear)
                    .tint(.primary)
            }
        }
    }

    // MARK: - Apps

    private var apps: some View {
        VStack(alignment: .leading, spacing: D.gap) {
            HStack {
                sectionLabel("RUNNING")
                Spacer()
                Text("\(viewModel.runningApps.count)")
                    .font(D.label.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if viewModel.runningApps.isEmpty {
                Text("None")
                    .font(D.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, D.rowV)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.runningApps.enumerated()), id: \.element.id) { i, app in
                        if i > 0 { hairline }
                        AppRow(app: app) { viewModel.closeApp(app) }
                    }
                }
                Button {
                    viewModel.closeAllApps()
                } label: {
                    Text("Close All").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Updates

    private var updates: some View {
        VStack(alignment: .leading, spacing: D.gap) {
            HStack {
                sectionLabel("UPDATES")
                Spacer()
                if viewModel.isCheckingUpdates {
                    ProgressView().controlSize(.small)
                }
            }

            if viewModel.updatesChecked {
                if viewModel.availableUpdates.isEmpty {
                    Text("Up to date")
                        .font(D.body)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, D.rowV)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.availableUpdates.enumerated()), id: \.element.id) { i, u in
                            if i > 0 { hairline }
                            UpdateRow(update: u)
                        }
                    }
                    HStack(spacing: 8) {
                        Button {
                            viewModel.downloadUpdates()
                        } label: {
                            Text(viewModel.isDownloadingUpdates ? "Downloading…" : "Download")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isDownloadingUpdates)

                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text("Install").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if !viewModel.downloadStatus.isEmpty {
                        Text(viewModel.downloadStatus)
                            .font(D.meta)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !viewModel.isCheckingUpdates {
                Text("Not checked")
                    .font(D.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, D.rowV)
            }

            if !viewModel.updatesChecked || !viewModel.availableUpdates.isEmpty {
                Button {
                    viewModel.checkForUpdates()
                } label: {
                    Text(viewModel.isCheckingUpdates ? "Checking…" : "Check for Updates")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isCheckingUpdates)
            }
        }
    }

    // MARK: - Atoms

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(D.label)
            .foregroundStyle(.secondary)
            .tracking(1.0)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: D.hair)
    }
}

// MARK: - Rows

private struct DiskRow: View {
    let item: CleanableItem
    @ObservedObject var viewModel: NazarViewModel

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { viewModel.selectedItems.contains(item.id) },
                set: { isOn in
                    if isOn { viewModel.selectedItems.insert(item.id) }
                    else { viewModel.selectedItems.remove(item.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("Include \(item.name) in cleanup")

            Text(item.name)
                .font(D.body)
                .lineLimit(1)

            if item.id == "downloads" || item.isCustom {
                Menu {
                    ForEach(AgeFilter.allCases, id: \.rawValue) { filter in
                        Button {
                            if item.isCustom { AgeFilter.setForFolder(item.id, filter) }
                            else { AgeFilter.currentDownloads = filter }
                            viewModel.calculateDiskUsage()
                        } label: {
                            HStack {
                                Text(filter.label)
                                if currentFilter() == filter { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if item.isCustom {
                        Divider()
                        Button(role: .destructive) {
                            viewModel.removeCustomFolder(itemId: item.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Spacer(minLength: 6)

            Text(item.sizeFormatted)
                .font(D.mono)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, D.rowV)
    }

    private func currentFilter() -> AgeFilter {
        item.isCustom ? AgeFilter.forFolder(item.id) : AgeFilter.currentDownloads
    }
}

private struct AppRow: View {
    let app: RunningApp
    let onClose: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
            }
            Text(app.name)
                .font(D.body)
                .lineLimit(1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Close \(app.name)")
            .accessibilityLabel("Close \(app.name)")
        }
        .padding(.vertical, D.rowV)
    }
}

private struct UpdateRow: View {
    let update: SystemUpdate
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(update.name)
                .font(D.body)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 10) {
                if !update.version.isEmpty {
                    Text(update.version)
                        .font(D.mono)
                        .foregroundStyle(.secondary)
                }
                if !update.size.isEmpty {
                    Text(update.size)
                        .font(D.mono)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, D.rowV)
    }
}
