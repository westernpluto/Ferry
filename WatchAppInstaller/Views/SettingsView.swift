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

    @State private var certificateSummary: String?
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
                Text("iOS only installs from HTTPS links it trusts. Either this app serves the file itself with your own certificate, or you upload it to a web server.")
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
            if let certificateSummary {
                LabeledContent("Certificate", value: certificateSummary)
                Button("Remove Certificate", role: .destructive) {
                    TLSIdentityStore.clear()
                    refreshCertificate()
                }
            } else {
                Label("No HTTPS certificate yet", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button("Add server.p12…") { showingImporter = true }

            if pendingP12 != nil {
                SecureField("Password", text: $password)
                Button("Save") { savePendingCertificate() }
            }
        } header: {
            Text("HTTPS certificate")
        } footer: {
            Text("This isn't your signing certificate. Create it with scripts/make-local-cert.sh, install rootCA.mobileconfig, then turn on full trust in Settings › General › About › Certificate Trust Settings.")
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

    private func refreshCertificate() {
        certificateSummary = TLSIdentityStore.loadIdentity().map { TLSIdentityStore.summary(of: $0) ?? "Installed" }
    }

    private func savePendingCertificate() {
        guard let data = pendingP12 else { return }
        do {
            try TLSIdentityStore.save(p12: data, password: password)
            pendingP12 = nil
            password = ""
            refreshCertificate()
            message = "Saved."
        } catch {
            message = error.localizedDescription
        }
    }
}
