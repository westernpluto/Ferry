import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var signing: SigningStore
    @AppStorage(SettingsKey.mode) private var mode: InstallMode = .local

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        SigningSettingsView()
                    } label: {
                        LabeledContent {
                            Text(signing.isReady ? "Ready" : "Not set up")
                        } label: {
                            Label("Signing", systemImage: "signature")
                        }
                    }
                    NavigationLink {
                        InstallMethodView()
                    } label: {
                        LabeledContent {
                            Text(mode.title)
                        } label: {
                            Label("Install Method", systemImage: "arrow.down.circle")
                        }
                    }
                } footer: {
                    Text("Signing lets you install your own builds with your certificate. Install Method controls how the app hands the IPA to iOS.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// How the IPA is served to iOS's installer.
struct InstallMethodView: View {
    @AppStorage(SettingsKey.mode) private var mode: InstallMode = .local
    @AppStorage(SettingsKey.port) private var port = SettingsDefault.port
    @AppStorage(SettingsKey.host) private var host = SettingsDefault.host
    @AppStorage(SettingsKey.remoteBaseURL) private var remoteBaseURL = ""

    @StateObject private var setup = LocalCertificateSetup()
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingNewRoot = false
    @State private var showingImporter = false
    @State private var pendingP12: Data?
    @State private var password = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("Serve from", selection: $mode) {
                    ForEach(InstallMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("iOS only installs from HTTPS links it trusts. Either this app serves the file itself, or you upload it to a web server.")
            }

            if mode == .local {
                localSection
            } else {
                remoteSection
            }
        }
        .navigationTitle("Install Method")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshCertificate)
        .onChange(of: scenePhase) { phase in
            // Re-check trust when coming back from the Settings app.
            if phase == .active { refreshCertificate() }
        }
        .onDisappear { setup.stopServing() }
        .confirmationDialog("Create a new root certificate?", isPresented: $confirmingNewRoot, titleVisibility: .visible) {
            Button("Create New Root", role: .destructive) { setup.generate(newRoot: true, host: host) }
        } message: {
            Text("You'll need to install and trust the new profile again. Remove the old one in Settings › General › VPN & Device Management.")
        }
        .onChange(of: setup.message) { newValue in
            guard let newValue else { return }
            message = newValue
            setup.message = nil
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pkcs12]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            pendingP12 = try? Data(contentsOf: url)
            if pendingP12 == nil { message = "Couldn't read that file." }
        }
        .alert("HTTPS Certificate", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private var localSection: some View {
        Section {
            certificateStatus
            if setup.isWorking {
                HStack { ProgressView(); Text("Creating certificate…") }
            } else if setup.status == .none {
                Button {
                    setup.generate(newRoot: false, host: host)
                } label: {
                    Label("Generate Certificate", systemImage: "wand.and.stars")
                        .font(.headline)
                }
            }
        } header: {
            Text("HTTPS certificate")
        } footer: {
            Text("iOS only installs from HTTPS links it trusts. This creates a certificate that only works for this iPhone (localhost and 127.0.0.1). It isn't your signing certificate.")
        }

        if setup.status == .needsTrust {
            Section {
                if setup.isGenerated {
                    Button {
                        setup.openProfileInSafari(port: port)
                    } label: {
                        Label("1. Download Profile in Safari", systemImage: "safari")
                    }
                    if let file = setup.profileFile {
                        ShareLink(item: file) {
                            Label("…or Save Profile to Files", systemImage: "folder")
                        }
                        .font(.callout)
                    }
                    Text("2. Open Settings › General › VPN & Device Management, tap “Watch App Installer Local Root” and install it.")
                } else {
                    Text("1. Install the profile for your certificate's root, e.g. rootCA.mobileconfig from scripts/make-local-cert.sh.")
                }
                Text("3. Open Settings › General › About › Certificate Trust Settings and turn on “Watch App Installer Local Root”.")
                Button("Check Again", action: refreshCertificate)
            } header: {
                Text("Trust it (once)")
            } footer: {
                Text("Safari asks to allow the download. If your default browser isn't Safari, use Save Profile to Files, then tap the file in the Files app.")
            }
            .font(.callout)
        }

        Section {
            TextField("Host", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(refreshCertificate)
            TextField("Port", value: $port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
        } header: {
            Text("Server")
        } footer: {
            Text("Only this iPhone can connect. Use 127.0.0.1 or localhost.")
        }

        Section {
            DisclosureGroup("Advanced") {
                if setup.status != .none && setup.isGenerated {
                    Button("Renew Server Certificate") { setup.generate(newRoot: false, host: host) }
                    Button("Create New Root…", role: .destructive) { confirmingNewRoot = true }
                }
                Button("Use My Own server.p12…") { showingImporter = true }
                if pendingP12 != nil {
                    SecureField("Password", text: $password)
                    Button("Save") { savePendingCertificate() }
                }
                if setup.status != .none {
                    Button("Remove Certificate", role: .destructive) {
                        TLSIdentityStore.clear()
                        LocalCertificate.forgetGenerated()
                        refreshCertificate()
                    }
                }
            }
        } footer: {
            Text("Renewing keeps the same root, so nothing needs to be reinstalled.")
        }

        Section {
            TextField("Host", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", value: $port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
        } header: {
            Text("Server")
        } footer: {
            Text("Only this iPhone can connect. The certificate must be valid for this host.")
        }
    }

    private var remoteSection: some View {
        Section {
            TextField("https://example.com/apps/", text: $remoteBaseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Web server folder")
        } footer: {
            Text("Where you'll upload manifest.plist and the IPA. It needs a normal, publicly trusted HTTPS certificate.")
        }
    }

    @ViewBuilder
    private var certificateStatus: some View {
        switch setup.status {
        case .none:
            Label("Not set up", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .needsTrust:
            Label("Created. Needs to be trusted (below).", systemImage: "hand.raised.fill")
                .foregroundStyle(.orange)
        case .trusted:
            VStack(alignment: .leading, spacing: 2) {
                Label("Ready", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let expiry = LocalCertificate.serverExpiresAt, setup.isGenerated {
                    Text("Valid until \(expiry.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func refreshCertificate() {
        setup.refresh(host: host)
    }

    private func savePendingCertificate() {
        guard let data = pendingP12 else { return }
        do {
            try TLSIdentityStore.save(p12: data, password: password)
            LocalCertificate.forgetGenerated()
            pendingP12 = nil
            password = ""
            refreshCertificate()
            message = "Saved."
        } catch {
            message = error.localizedDescription
        }
    }
}
