import SwiftUI
import UniformTypeIdentifiers

/// Your signing certificate and provisioning profiles.
struct SigningSettingsView: View {
    @EnvironmentObject private var signing: SigningStore

    private enum ImportKind { case certificate, profiles }

    // Which button opened the picker. Kept separately from `showingImporter`, because the
    // picker's binding is reset to false before its completion handler runs.
    @State private var importKind: ImportKind = .certificate
    @State private var showingImporter = false
    @State private var pendingP12: Data?
    @State private var pendingP12Name = ""
    @State private var password = ""
    @State private var message: String?
    @FocusState private var passwordFocused: Bool

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
            isPresented: $showingImporter,
            allowedContentTypes: importKind == .certificate ? [.pkcs12, .data] : [.mobileProvision, .data],
            allowsMultipleSelection: importKind == .profiles
        ) { result in
            handleImport(result, kind: importKind)
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
                Button("Replace Certificate…") { pick(.certificate) }
                Button("Remove Certificate", role: .destructive) { signing.removeCertificate() }
            } else {
                Button {
                    pick(.certificate)
                } label: {
                    Label("Add Certificate (.p12)…", systemImage: "plus.circle.fill")
                }
            }

            if pendingP12 != nil {
                Label(pendingP12Name, systemImage: "doc.badge.ellipsis")
                    .foregroundStyle(.secondary)
                SecureField("Certificate password", text: $password)
                    .focused($passwordFocused)
                    .submitLabel(.done)
                    .onSubmit(saveCertificate)
                Button("Save Certificate", action: saveCertificate)
                    .bold()
                Button("Cancel", role: .cancel) {
                    pendingP12 = nil
                    password = ""
                }
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
                pick(.profiles)
            } label: {
                Label("Add Profiles…", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Provisioning profiles")
        } footer: {
            Text("You can also open .mobileprovision files from Files, Mail or AirDrop with this app.")
        }
    }

    private func pick(_ kind: ImportKind) {
        importKind = kind
        showingImporter = true
    }

    private func handleImport(_ result: Result<[URL], Error>, kind: ImportKind) {
        let urls: [URL]
        switch result {
        case .success(let picked):
            urls = picked
        case .failure(let error):
            message = error.localizedDescription
            return
        }
        guard !urls.isEmpty else { return }

        switch kind {
        case .certificate:
            let url = urls[0]
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                pendingP12 = try Data(contentsOf: url)
                pendingP12Name = url.lastPathComponent
                password = ""
                // Give the picker time to dismiss before moving focus.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    passwordFocused = true
                }
            } catch {
                message = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        case .profiles:
            let before = signing.profiles.count
            let problems = signing.importProfiles(from: urls)
            if !problems.isEmpty {
                message = problems.joined(separator: "\n")
            } else if signing.profiles.count == before {
                message = "That profile was already added, so it was replaced with the new copy."
            }
        }
    }

    private func saveCertificate() {
        guard let data = pendingP12 else { return }
        do {
            try signing.importCertificate(p12: data, password: password)
            pendingP12 = nil
            password = ""
            passwordFocused = false
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
