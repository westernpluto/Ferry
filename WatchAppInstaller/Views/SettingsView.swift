import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
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
        NavigationStack {
            Form {
                Section {
                    Picker("Serve the app from", selection: $mode) {
                        ForEach(InstallMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("iOS only installs apps from HTTPS links with a trusted certificate. Choose whether this app serves the IPA itself, using your own certificate, or you upload it to a web server.")
                }

                if mode == .local {
                    localSection
                } else {
                    remoteSection
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: refreshCertificate)
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pkcs12]) { result in
                guard case .success(let url) = result else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                pendingP12 = try? Data(contentsOf: url)
                if pendingP12 == nil { message = "Could not read that file." }
            }
            .alert("Certificate", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    @ViewBuilder
    private var localSection: some View {
        Section {
            if let certificateSummary {
                LabeledContent("Certificate", value: certificateSummary)
                Button("Remove certificate", role: .destructive) {
                    TLSIdentityStore.clear()
                    refreshCertificate()
                }
            } else {
                Label("No certificate imported", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button("Import .p12 certificate…") { showingImporter = true }

            if pendingP12 != nil {
                SecureField("Password for .p12", text: $password)
                Button("Save certificate") { savePendingCertificate() }
            }
        } header: {
            Text("TLS certificate")
        } footer: {
            Text("Create one with scripts/make-local-cert.sh. Install the generated profile, then turn on full trust for its root certificate in Settings › General › About › Certificate Trust Settings.")
        }

        Section {
            TextField("Host", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", value: $port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
        } header: {
            Text("Local server")
        } footer: {
            Text("The certificate must be valid for this host name. The server only accepts connections from this iPhone.")
        }
    }

    private var remoteSection: some View {
        Section {
            TextField("https://example.com/apps/", text: $remoteBaseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Web server")
        } footer: {
            Text("The folder where you'll upload manifest.plist and the IPA. It must use HTTPS with a publicly trusted certificate.")
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
            message = "Certificate saved."
        } catch {
            message = error.localizedDescription
        }
    }
}
