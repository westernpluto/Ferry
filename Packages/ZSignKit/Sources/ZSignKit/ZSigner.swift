import Foundation
import CZSign

/// A provisioning profile and the entitlements to sign one bundle with.
/// The entitlements' `application-identifier` (`TEAMID.bundle.id`) decides which bundle it signs.
public struct ZSignProfile: Sendable {
    public var profileURL: URL
    public var entitlementsURL: URL

    public init(profileURL: URL, entitlementsURL: URL) {
        self.profileURL = profileURL
        self.entitlementsURL = entitlementsURL
    }
}

public struct ZSignError: LocalizedError, Sendable {
    public var code: Int32
    public var messages: [String]

    public var errorDescription: String? {
        let detail = messages.last.map { $0.replacingOccurrences(of: ">>> ", with: "") }
        return detail ?? "Signing failed (code \(code))."
    }
}

public enum ZSigner {
    /// Re-signs every bundle in `input` and writes the result to `output`. Blocks until done;
    /// call it off the main thread. `log` is called on the signing thread.
    public static func signIPA(
        input: URL,
        output: URL,
        keyURL: URL,
        certificateURL: URL?,
        password: String?,
        profiles: [ZSignProfile],
        temporaryDirectory: URL,
        bundleVersion: String? = nil,
        log: @escaping @Sendable (_ message: String, _ isError: Bool) -> Void
    ) throws {
        let box = LogBox(handler: log)
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<LogBox>.fromOpaque(context).release() }

        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func cString(_ value: String) -> UnsafePointer<CChar> {
            let pointer = strdup(value)!
            owned.append(pointer)
            return UnsafePointer(pointer)
        }

        let cProfiles = profiles.map {
            czsign_profile(profile_path: cString($0.profileURL.path), entitlements_path: cString($0.entitlementsURL.path))
        }

        let callback: czsign_log_callback = { context, isError, message in
            guard let context, let message else { return }
            let box = Unmanaged<LogBox>.fromOpaque(context).takeUnretainedValue()
            let text = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if isError != 0 { box.errors.append(text) }
            box.handler(text, isError != 0)
        }

        let inputPath = cString(input.path)
        let outputPath = cString(output.path)
        let keyPath = cString(keyURL.path)
        let certificatePath = certificateURL.map { cString($0.path) }
        let passwordValue = password.map { cString($0) }
        let tempPath = cString(temporaryDirectory.path)
        let versionValue = bundleVersion.map { cString($0) }

        let result = cProfiles.withUnsafeBufferPointer { buffer in
            czsign_sign_ipa(
                inputPath, outputPath, keyPath, certificatePath, passwordValue,
                buffer.baseAddress, Int32(buffer.count), tempPath, versionValue, callback, context
            )
        }
        guard result == 0 else {
            throw ZSignError(code: result, messages: box.errors)
        }
    }
}

private final class LogBox {
    let handler: @Sendable (String, Bool) -> Void
    var errors: [String] = []

    init(handler: @escaping @Sendable (String, Bool) -> Void) {
        self.handler = handler
    }
}
