import SwiftUI
import UniformTypeIdentifiers

/// Your signing certificate and provisioning profiles.
struct SigningSettingsView: View {
    @EnvironmentObject private var signing: SigningStore

    private enum ImportKind { case certificate, profiles }

    @State private var importKind: ImportKind?
    @State private var pendingP12: Data?
    @State private var password = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Sign apps before installing", isOn: $signing.signBeforeInstall)
            } footer: {
                Text("Re-signs each app with your certificate, so builds that are unsigned, App Store-signed or signed by someone else can be installed on your devices.")
            }

            certificateSection
            profilesSection

            Section("What you need") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Your certificate as a .p12: in Keychain Access on a Mac, right-click your Apple Development or Apple Distribution certificate › Export.")
                    Text("2. A .mobileprovision for each app ID: the iPhone app, the watch app and each extension. A wildcard profile (com.you.*) covers them all if the app uses no special capabilities.")
                    Text("3. Profiles must include your iPhone's and Apple Watch's UDIDs (Development and Ad Hoc).")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Signing")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }),
            allowedContentTypes: importKind == .certificate ? [.pkcs12] : [.mobileProvision, .data],
            allowsMultipleSelection: importKind == .profiles
        ) { result in
            let kind = importKind
            importKind = nil
            guard case .success(let urls) = result else { return }
            switch kind {
            case .certificate:
                guard let url = urls.first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                pendingP12 = try? Data(contentsOf: url)
                if pendingP12 == nil { message = "Couldn't read that file." }
            case .profiles:
                let problems = signing.importProfiles(from: urls)
                if !problems.isEmpty { message = problems.joined(separator: "\n") }
            case nil:
                break
            }
        }
        .alert("Signing", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var certificateSection: some View {
        Section {
            if let certificate = signing.certificate {
                Label {
                    Text(certificate.name)
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                Button("Replace Certificate…") { importKind = .certificate }
                Button("Remove Certificate", role: .destructive) { signing.removeCertificate() }
            } else {
                Button {
                    importKind = .certificate
                } label: {
                    Label("Add Certificate (.p12)…", systemImage: "plus.circle.fill")
                }
            }

            if pendingP12 != nil {
                SecureField("Certificate password", text: $password)
                    .submitLabel(.done)
                    .onSubmit(saveCertificate)
                Button("Save Certificate", action: saveCertificate)
                    .bold()
            }
        } header: {
            Text("Certificate")
        } footer: {
            Text("Stored in this iPhone's Keychain and never sent anywhere.")
        }
    }

    private var profilesSection: some View {
        Section {
            ForEach(signing.profiles) { stored in
                ProfileRow(stored: stored, matchesCertificate: signing.matchesCertificate(stored))
            }
            .onDelete { offsets in
                for stored in offsets.map({ signing.profiles[$0] }) {
                    signing.deleteProfile(stored)
                }
            }
            Button {
                importKind = .profiles
            } label: {
                Label("Add Profiles…", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Provisioning profiles")
        } footer: {
            Text("You can also open .mobileprovision files from Files, Mail or AirDrop with this app.")
        }
    }

    private func saveCertificate() {
        guard let data = pendingP12 else { return }
        do {
            try signing.importCertificate(p12: data, password: password)
            pendingP12 = nil
            password = ""
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct ProfileRow: View {
    let stored: StoredProfile
    let matchesCertificate: Bool

    private var profile: ProvisioningProfile { stored.profile }

    private var problem: String? {
        if profile.isExpired() { return "Expired" }
        if !profile.allowsDirectInstall { return "App Store profile — can't be used" }
        if !matchesCertificate { return "Doesn't include your certificate" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(profile.name).font(.body)
            Text(profile.bundleIDPattern ?? "Unknown app ID")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(profile.kind.displayName)
                if let expiry = profile.expirationDate {
                    Text("· expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
                }
                if let devices = profile.provisionedDevices {
                    Text("· \(devices.count) devices")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}
