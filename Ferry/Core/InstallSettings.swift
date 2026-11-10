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
    // New key: the default changed from 127.0.0.1, which iOS's installer won't fetch from.
    static let host = "localHostName"
    static let remoteBaseURL = "remoteBaseURL"
}

enum SettingsDefault {
    static let port = 8443
    static let host = "127-0-0-1.sslip.io"
}

/// Addresses the local install server can be reached at. All point to this iPhone; the
/// public names resolve to 127.0.0.1 via DNS, which iOS's installer accepts where it
/// rejects a bare IP address. Ferry's certificate covers all of them.
enum LocalHostOption: String, CaseIterable, Identifiable {
    case sslip = "127-0-0-1.sslip.io"
    case localtest = "ferry.localtest.me"
    case localhost = "localhost"
    case loopbackIP = "127.0.0.1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sslip: return "127-0-0-1.sslip.io (recommended)"
        case .localtest: return "ferry.localtest.me"
        case .localhost: return "localhost"
        case .loopbackIP: return "127.0.0.1"
        }
    }

    var needsInternet: Bool { self == .sslip || self == .localtest }
}
