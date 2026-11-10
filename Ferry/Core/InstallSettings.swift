import Foundation

enum InstallMode: String, CaseIterable, Identifiable {
    /// Serve the IPA from a loopback HTTPS server inside this app.
    case local
    /// Use an HTTPS web server you control.
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "On this iPhone"
        case .remote: return "My web server"
        }
    }
}

enum SettingsKey {
    static let mode = "installMode"
    static let port = "localPort"
    static let host = "localHost"
    static let remoteBaseURL = "remoteBaseURL"
}

enum SettingsDefault {
    static let port = 8443
    static let host = "127.0.0.1"
}
