// Apple TV screens, ported from iOStoATV: pair, see the TV's UDID, list and remove apps.
// Installing happens from an Apple TV app's page in the library (signed first, like any app).
import SwiftUI
import UIKit

struct AppleTVListView: View {
    @EnvironmentObject private var appleTV: AppleTVStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var pairingID: String?
    @State private var errorMessage: String?
    @State private var showManual = false
    @State private var manualRequest: AppleTVManualRequest?

    var body: some View {
        List {
            if let problem = appleTV.browser.problem {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Can't search for Apple TVs", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(problem).font(.callout).foregroundStyle(.secondary)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Paired") {
                if appleTV.devices.isEmpty {
                    Text("No Apple TVs paired yet.").foregroundStyle(.secondary)
                }
                ForEach(appleTV.devices) { device in
                    NavigationLink {
                        AppleTVDeviceView(deviceID: device.id)
                    } label: {
                        AppleTVRow(device: device, online: appleTV.isOnline(device))
                    }
                }
                .onDelete { offsets in
                    offsets.map { appleTV.devices[$0] }.forEach(appleTV.remove)
                }
            }

            Section {
                if appleTV.browser.pairable.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for Apple TVs in pairing mode…").foregroundStyle(.secondary)
                    }
                }
                ForEach(appleTV.browser.pairable) { service in
                    Button {
                        pair(service)
                    } label: {
                        HStack {
                            Label(service.name, systemImage: "appletv")
                            Spacer()
                            if pairingID == service.id {
                                ProgressView()
                            } else {
                                Text("Pair").foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(pairingID != nil)
                }
                Button {
                    showManual = true
                } label: {
                    Label("Pair by IP Address…", systemImage: "network")
                }
                .disabled(pairingID != nil)
            } header: {
                Text("Ready to Pair")
            } footer: {
                Text("On your Apple TV (tvOS 17 or later), open Settings › Remotes and Devices › Remote App and Devices. It shows up here while that screen is open. Then copy its UDID into your provisioning profiles, and install tvOS apps from their page in your library.")
            }
        }
        .navigationTitle("Apple TV")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { appleTV.browser.restart() }
        .onAppear { appleTV.startBrowsing() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { appleTV.browser.appBecameActive() }
        }
        .sheet(item: $appleTV.pinRequest) { request in
            AppleTVPinEntryView(request: request)
        }
        .sheet(isPresented: $showManual, onDismiss: startManualPairing) {
            AppleTVManualPairView { manualRequest = $0 }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func pair(_ service: AppleTVService) {
        pairingID = service.id
        Task {
            defer { pairingID = nil }
            do {
                _ = try await appleTV.pair(service: service)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startManualPairing() {
        guard let request = manualRequest else { return }
        manualRequest = nil
        pairingID = "manual"
        Task {
            defer { pairingID = nil }
            do {
                _ = try await appleTV.pair(host: request.host, port: request.port)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AppleTVRow: View {
    let device: PairedAppleTV
    let online: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "appletv.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(online ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .accessibilityLabel(online ? "Online" : "Not seen on network")
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let version = device.info?.osVersion { parts.append("tvOS \(version)") }
        if let model = device.info?.productType ?? device.model { parts.append(model) }
        return parts.isEmpty ? "Paired" : parts.joined(separator: " · ")
    }
}

struct AppleTVDeviceView: View {
    let deviceID: UUID
    @EnvironmentObject private var appleTV: AppleTVStore
    @EnvironmentObject private var store: PackageStore
    @EnvironmentObject private var history: InstallHistory
    @EnvironmentObject private var sources: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var apps: [AppleTVApp] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var confirmUninstall: AppleTVApp?
    @State private var busyBundle: String?
    @State private var confirmForget = false
    @State private var errorMessage: String?
    @State private var copied = false

    private var device: PairedAppleTV? { appleTV.device(deviceID) }

    var body: some View {
        List {
            if let device {
                infoSection(device)
            }
            appsSection
            Section {
                Button("Forget This Apple TV", role: .destructive) { confirmForget = true }
            }
        }
        .navigationTitle(device?.displayName ?? "Apple TV")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog(
            "Remove \(confirmUninstall?.name ?? "app")?",
            isPresented: Binding(get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } }),
            titleVisibility: .visible,
            presenting: confirmUninstall
        ) { app in
            Button("Remove from Apple TV", role: .destructive) { uninstall(app) }
        } message: { _ in
            Text("The app and its data will be deleted from the Apple TV.")
        }
        .confirmationDialog("Forget this Apple TV?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                if let device {
                    appleTV.remove(device)
                    dismiss()
                }
            }
        } message: {
            Text("You'll need to pair again to install apps. You can also remove this iPhone on the Apple TV under Settings › Remotes and Devices › Remote App and Devices.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func infoSection(_ device: PairedAppleTV) -> some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "appletv.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.displayName).font(.title3.weight(.semibold))
                    if let version = device.info?.osVersion {
                        Text("tvOS \(version)\(device.info?.buildVersion.map { " (\($0))" } ?? "")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)

            if let model = device.info?.productType ?? device.model {
                LabeledContent("Model", value: model)
            }
            if let udid = device.info?.udid {
                Button {
                    UIPasteboard.general.string = udid
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("UDID").foregroundStyle(.primary)
                            Spacer()
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                        }
                        Text(udid)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            if let address = device.lastAddress {
                LabeledContent("Address", value: address.host)
            }
        } footer: {
            Text("Apps must be signed with a profile that includes this UDID, or the Apple TV refuses them. Add the UDID to your profiles on developer.apple.com, then import the new profiles in Settings › Signing.")
        }
    }

    @ViewBuilder private var appsSection: some View {
        Section {
            if loading && apps.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting…").foregroundStyle(.secondary)
                }
            } else if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Couldn't connect", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(loadError).font(.caption).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await reload() } }
                        .font(.callout)
                }
                .padding(.vertical, 4)
            } else if apps.isEmpty {
                Text("No apps reported.").foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text([app.bundleId, app.version].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let summary = status(of: app)?.summary {
                            Text(summary).font(.caption.bold()).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if busyBundle == app.bundleId { ProgressView() }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { confirmUninstall = app }
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = app.bundleId
                    } label: {
                        Label("Copy Bundle ID", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        confirmUninstall = app
                    } label: {
                        Label("Remove from Apple TV", systemImage: "trash")
                    }
                }
            }
        } header: {
            HStack {
                Text("Installed Apps")
                Spacer()
                if loading && !apps.isEmpty { ProgressView().controlSize(.small) }
            }
        } footer: {
            let tvApps = store.packages.filter(\.isAppleTVApp).count
            Text(tvApps == 0
                 ? "Add a tvOS .ipa to your library (or get one from a source), then install it from its page."
                 : "To install, open an Apple TV app in your library and tap Install on Apple TV.")
        }
    }

    /// Update / expiry status for an app on this TV, if Ferry knows where it comes from.
    private func status(of app: AppleTVApp) -> InstallStatus? {
        guard let record = history.records.first(where: {
            $0.destination.key == deviceID.uuidString && $0.installedBundleIdentifier == app.bundleId
        }) else { return nil }
        return history.status(of: record, packages: store.packages, sources: sources)
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            apps = try await appleTV.listApps(deviceID)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func uninstall(_ app: AppleTVApp) {
        busyBundle = app.bundleId
        Task {
            defer { busyBundle = nil }
            do {
                try await appleTV.uninstall(deviceID, bundleId: app.bundleId)
                apps.removeAll { $0.bundleId == app.bundleId }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct AppleTVPinEntryView: View {
    let request: AppleTVPinRequest
    @EnvironmentObject private var appleTV: AppleTVStore
    @State private var pin = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "appletv.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .padding(.top, 32)
                Text("Enter the code shown on \(request.deviceName)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                TextField("0000", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .padding(.vertical, 12)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 48)
                    .onSubmit(submit)
                Button(action: submit) {
                    Text("Pair").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 48)
                .disabled(pin.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .navigationTitle("Pair Apple TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(nil) }
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear { focused = true }
        // Covers any dismissal path we didn't start.
        .onDisappear { request.respond(nil) }
    }

    private func submit() {
        let trimmed = pin.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        finish(trimmed)
    }

    private func finish(_ value: String?) {
        request.respond(value)
        appleTV.pinRequest = nil
    }
}

struct AppleTVManualRequest {
    var host: String
    var port: UInt16?
}

struct AppleTVManualPairView: View {
    var onSubmit: (AppleTVManualRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP address (e.g. 192.168.1.20)", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port (optional)", text: $port)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Use this if your Apple TV doesn't show up automatically. Put the TV on Settings › Remotes and Devices › Remote App and Devices first. Leave the port empty and Ferry asks the TV for it. The TV's IP address is under Settings › Network on the Apple TV.")
                }
            }
            .navigationTitle("Pair by IP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        onSubmit(AppleTVManualRequest(host: host.trimmingCharacters(in: .whitespaces), port: UInt16(port)))
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || (!port.isEmpty && UInt16(port) == nil))
                }
            }
        }
    }
}
