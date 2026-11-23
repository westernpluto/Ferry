import SwiftUI

/// Choose the bundle IDs and team an app is signed with, so it matches the profiles you have
/// instead of the ones the app asks for. Saved per app (by its original bundle ID), so updates
/// from a source are signed the same way.
struct SigningOverrideView: View {
    let package: AppPackage

    @EnvironmentObject private var signing: SigningStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = SigningOverride()
    @State private var appIdentifier = ""
    @State private var noMatch = false

    private var plan: SigningPlan {
        SigningPlanner.plan(for: package, profiles: signing.profiles,
                            certificateFingerprint: signing.certificate?.fingerprint, override: draft)
    }

    /// Explicit App IDs from usable profiles, for quick picking.
    private var profileIdentifiers: [String] {
        let usable = SigningPlanner.usableProfiles(signing.profiles, certificateFingerprint: signing.certificate?.fingerprint,
                                                   team: draft.teamIdentifier)
        return Array(Set(usable.compactMap { $0.profile.isWildcard ? nil : $0.profile.bundleIDPattern })).sorted()
    }

    var body: some View {
        Form {
            Section {
                Button {
                    if let suggestion = SigningPlanner.suggestOverride(
                        for: package, profiles: signing.profiles,
                        certificateFingerprint: signing.certificate?.fingerprint, keeping: draft
                    ) {
                        draft = suggestion
                        appIdentifier = suggestion.bundleIdentifier(for: package.container.bundleIdentifier)
                    } else {
                        noMatch = true
                    }
                } label: {
                    Label("Match My Profiles", systemImage: "wand.and.stars")
                }
            } footer: {
                Text("Picks bundle IDs your profiles cover, keeping the app and its extensions together on one team.")
            }

            if signing.teams.count > 1 {
                Section {
                    Picker("Team", selection: Binding(
                        get: { draft.teamIdentifier ?? "" },
                        set: { draft.teamIdentifier = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Any").tag("")
                        ForEach(signing.teams, id: \.id) { team in
                            Text("\(team.name) (\(team.id))").tag(team.id)
                        }
                    }
                } footer: {
                    Text("Only use profiles from this team.")
                }
            }

            Section {
                identifierField(
                    title: package.container.displayName,
                    original: package.container.bundleIdentifier,
                    text: $appIdentifier
                )
                .onChange(of: appIdentifier) { newValue in
                    let original = package.container.bundleIdentifier
                    let wanted = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Only move the extensions when the app's ID was actually edited.
                    guard (wanted.isEmpty ? original : wanted) != draft.bundleIdentifier(for: original) else { return }
                    draft.rebase(package, to: wanted.isEmpty ? original : wanted)
                }
            } header: {
                Text("App")
            } footer: {
                Text("Extensions and watch apps under the app's ID move with it (\(package.container.bundleIdentifier).widget → <new ID>.widget).")
            }

            let others = package.signableBundles.filter { $0.path != package.container.path }
            if !others.isEmpty {
                Section("Extensions & Watch Apps") {
                    ForEach(others, id: \.path) { bundle in
                        identifierField(
                            title: bundle.displayName,
                            original: bundle.bundleIdentifier,
                            text: Binding(
                                get: { draft.bundleIdentifier(for: bundle.bundleIdentifier) },
                                set: { value in
                                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                    draft.bundleIdentifiers[bundle.bundleIdentifier] =
                                        trimmed.isEmpty || trimmed == bundle.bundleIdentifier ? nil : trimmed
                                }
                            )
                        )
                    }
                }
            }

            Section {
                Button("Use the App's Own Bundle IDs", role: .destructive) {
                    draft = SigningOverride()
                    appIdentifier = package.container.bundleIdentifier
                }
            } footer: {
                Text("A different bundle ID installs as a separate app from the original. App Groups, iCloud and other capabilities come from your profiles.")
            }
        }
        .navigationTitle("Bundle IDs & Team")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    signing.setOverride(draft, for: package)
                    dismiss()
                }
            }
        }
        .onAppear {
            draft = signing.signingOverride(for: package) ?? SigningOverride()
            appIdentifier = draft.bundleIdentifier(for: package.container.bundleIdentifier)
        }
        .alert("No Match", isPresented: $noMatch) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("None of your profiles fit this app. Add a profile for the bundle IDs you want (a wildcard profile like com.you.* covers any), then try again.")
        }
    }

    private func identifierField(title: String, original: String, text: Binding<String>) -> some View {
        let current = text.wrappedValue.isEmpty ? original : text.wrappedValue
        let profile = plan.assignments.first { $0.bundleIdentifier == current }?.profile
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Menu {
                    Button("Original: \(original)") { text.wrappedValue = original }
                    if !profileIdentifiers.isEmpty {
                        Section("Your Profiles") {
                            ForEach(profileIdentifiers, id: \.self) { id in
                                Button(id) { text.wrappedValue = id }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet.circle")
                }
                .accessibilityLabel("Choose a bundle ID")
            }
            TextField(original, text: text)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Label(profile.map { "Profile: \($0.profile.name)" } ?? "No profile covers this ID",
                  systemImage: profile == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(profile == nil ? .red : .green)
        }
        .padding(.vertical, 2)
    }
}
