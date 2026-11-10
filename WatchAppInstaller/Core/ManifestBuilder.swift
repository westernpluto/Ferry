import Foundation

/// Builds the manifest and `itms-services` link that iOS uses for over-the-air app installs.
enum ManifestBuilder {
    static func manifest(ipaURL: URL, bundleIdentifier: String, bundleVersion: String, title: String) throws -> Data {
        let plist: [String: Any] = [
            "items": [
                [
                    "assets": [
                        ["kind": "software-package", "url": ipaURL.absoluteString],
                    ],
                    "metadata": [
                        "bundle-identifier": bundleIdentifier,
                        "bundle-version": bundleVersion,
                        "kind": "software",
                        "title": title,
                    ],
                ],
            ],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func manifest(for package: AppPackage, ipaURL: URL) throws -> Data {
        try manifest(
            ipaURL: ipaURL,
            bundleIdentifier: package.container.bundleIdentifier,
            bundleVersion: package.container.shortVersion,
            title: package.title
        )
    }

    /// `itms-services://?action=download-manifest&url=<percent-encoded manifest URL>`
    static func installURL(manifestURL: URL) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = manifestURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "itms-services://?action=download-manifest&url=\(encoded)")
    }
}
