import XCTest
@testable import WatchAppInstaller

final class ProvisioningProfileTests: XCTestCase {
    func testParsesPlistEmbeddedInCMSBlob() throws {
        let profile = try ProvisioningProfile.parse(TestData.profileBlob(devices: ["00008006-000A1B2C3D4E5F60"]))
        XCTAssertEqual(profile.name, "Test Ad Hoc")
        XCTAssertEqual(profile.teamIdentifiers, ["ABCDE12345"])
        XCTAssertEqual(profile.kind, .adHoc)
        XCTAssertTrue(profile.includesDevice(" 00008006-000a1b2c3d4e5f60 "))
        XCTAssertFalse(profile.includesDevice("1234"))
        XCTAssertFalse(profile.isExpired(at: Date(timeIntervalSince1970: 0)))
    }

    func testKinds() throws {
        XCTAssertEqual(try ProvisioningProfile.parse(TestData.profileBlob(devices: nil)).kind, .appStore)
        XCTAssertEqual(try ProvisioningProfile.parse(TestData.profileBlob(devices: [], getTaskAllow: true)).kind, .development)
        XCTAssertEqual(try ProvisioningProfile.parse(TestData.profileBlob(devices: nil, allDevices: true)).kind, .enterprise)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try ProvisioningProfile.parse(Data([0x30, 0x82, 0x01])))
    }
}

final class ManifestBuilderTests: XCTestCase {
    func testManifestAndInstallURL() throws {
        let ipa = URL(string: "https://127.0.0.1:8443/x/app.ipa")!
        let data = try ManifestBuilder.manifest(ipaURL: ipa, bundleIdentifier: "com.a.b", bundleVersion: "1.2", title: "Hi")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let item = try XCTUnwrap((plist["items"] as? [[String: Any]])?.first)
        let asset = try XCTUnwrap((item["assets"] as? [[String: String]])?.first)
        XCTAssertEqual(asset["url"], ipa.absoluteString)
        XCTAssertEqual((item["metadata"] as? [String: String])?["bundle-identifier"], "com.a.b")

        let link = ManifestBuilder.installURL(manifestURL: URL(string: "https://127.0.0.1:8443/x/manifest.plist")!)
        XCTAssertEqual(link?.absoluteString,
                       "itms-services://?action=download-manifest&url=https%3A%2F%2F127.0.0.1%3A8443%2Fx%2Fmanifest.plist")
    }
}

final class HTTPMessageTests: XCTestCase {
    func testParsesRequest() {
        let raw = Data("GET /abc/app%20x.ipa?x=1 HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-9\r\n\r\n".utf8)
        let request = HTTPRequest.parse(raw)
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/abc/app x.ipa")
        XCTAssertEqual(request?.headers["range"], "bytes=0-9")
    }

    func testIncompleteRequest() {
        XCTAssertNil(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
    }

    func testRanges() {
        XCTAssertNil(ByteRange.parse(nil, resourceSize: 100) as ByteRange??)
        XCTAssertEqual(ByteRange.parse("bytes=10-19", resourceSize: 100), .some(ByteRange(lowerBound: 10, upperBound: 19)))
        XCTAssertEqual(ByteRange.parse("bytes=90-", resourceSize: 100), .some(ByteRange(lowerBound: 90, upperBound: 99)))
        XCTAssertEqual(ByteRange.parse("bytes=-5", resourceSize: 100), .some(ByteRange(lowerBound: 95, upperBound: 99)))
        XCTAssertEqual(ByteRange.parse("bytes=50-500", resourceSize: 100), .some(ByteRange(lowerBound: 50, upperBound: 99)))
        XCTAssertEqual(ByteRange.parse("bytes=200-", resourceSize: 100), .some(nil))
    }
}

final class PackageValidatorTests: XCTestCase {
    func testValidAdHocPackageHasNoErrors() throws {
        let package = try TestData.package()
        XCTAssertTrue(package.canInstall, "\(package.issues)")
    }

    func testMissingWatchAppIsOnlyAWarning() throws {
        var package = try TestData.package()
        package.watchApps = []
        XCTAssertTrue(package.canInstall)
        XCTAssertTrue(package.issues.contains { $0.severity == .warning })
    }

    func testBareWatchBinaryCannotBeFixedBySigning() throws {
        var package = try TestData.package()
        package.container = package.watchApps[0]
        XCTAssertTrue(package.structuralIssues.contains { $0.severity == .error })
    }

    func testSigningIssuesAreMarked() throws {
        var package = try TestData.package()
        package.container.profile = nil
        let problem = try XCTUnwrap(package.issues.first { $0.severity == .error })
        XCTAssertTrue(problem.isSigning)
        XCTAssertFalse(package.structuralIssues.contains { $0.severity == .error })
    }

    func testAppStoreProfileIsError() throws {
        var package = try TestData.package()
        package.container.profile = try ProvisioningProfile.parse(TestData.profileBlob(devices: nil))
        XCTAssertFalse(package.canInstall)
    }

    func testExpiredProfileIsError() throws {
        let package = try TestData.package()
        let future = Date().addingTimeInterval(20 * 365 * 24 * 3600)
        XCTAssertTrue(PackageValidator.validate(package, now: future).contains { $0.severity == .error })
    }
}

final class SigningPlannerTests: XCTestCase {
    private func stored(_ appID: String, devices: [String]? = ["abc"], expires: TimeInterval = 3600) throws -> StoredProfile {
        var profile = try ProvisioningProfile.parse(TestData.profileBlob(devices: devices))
        profile.applicationIdentifier = appID
        profile.expirationDate = Date().addingTimeInterval(expires)
        return StoredProfile(id: UUID(), fileName: "x", profile: profile, importedAt: Date())
    }

    func testCovers() throws {
        let wildcard = try stored("ABCDE12345.com.example.*").profile
        XCTAssertTrue(wildcard.covers(bundleIdentifier: "com.example.app.watchkitapp"))
        XCTAssertFalse(wildcard.covers(bundleIdentifier: "org.other.app"))
        let exact = try stored("ABCDE12345.com.example.app").profile
        XCTAssertTrue(exact.covers(bundleIdentifier: "com.example.app"))
        XCTAssertFalse(exact.covers(bundleIdentifier: "com.example.app.watchkitapp"))
        XCTAssertEqual(exact.appIDPrefix, "ABCDE12345")
    }

    func testExactProfileBeatsWildcard() throws {
        let package = try TestData.package()
        let wildcard = try stored("ABCDE12345.*")
        let exactWatch = try stored("ABCDE12345.com.example.app.watchkitapp")
        let plan = SigningPlanner.plan(for: package, profiles: [wildcard, exactWatch], certificateFingerprint: nil)
        XCTAssertTrue(plan.isComplete)
        let watch = try XCTUnwrap(plan.assignments.first { $0.bundle.isWatchApp })
        XCTAssertEqual(watch.profile.id, exactWatch.id)
        XCTAssertEqual(watch.applicationIdentifier, "ABCDE12345.com.example.app.watchkitapp")
        let container = try XCTUnwrap(plan.assignments.first { !$0.bundle.isWatchApp })
        XCTAssertEqual(container.profile.id, wildcard.id)
    }

    func testMissingAndUnusableProfiles() throws {
        let package = try TestData.package()
        let expired = try stored("ABCDE12345.*", expires: -60)
        let appStore = try stored("ABCDE12345.*", devices: nil)
        let containerOnly = try stored("ABCDE12345.com.example.app")
        let plan = SigningPlanner.plan(for: package, profiles: [expired, appStore, containerOnly], certificateFingerprint: nil)
        XCTAssertFalse(plan.isComplete)
        XCTAssertEqual(plan.missing.map(\.bundleIdentifier), ["com.example.app.watchkitapp"])
    }

    func testCertificateMustBeInProfile() throws {
        var profile = try stored("ABCDE12345.*")
        profile.profile.certificateFingerprints = ["aaaa"]
        let package = try TestData.package()
        XCTAssertFalse(SigningPlanner.plan(for: package, profiles: [profile], certificateFingerprint: "bbbb").isComplete)
        XCTAssertTrue(SigningPlanner.plan(for: package, profiles: [profile], certificateFingerprint: "AAAA").isComplete)
    }

    func testEntitlementsAreMadeConcrete() {
        let source: [String: Any] = [
            "application-identifier": "ABCDE12345.*",
            "keychain-access-groups": ["ABCDE12345.*", "com.apple.token"],
            "com.apple.developer.associated-domains": "*",
            "get-task-allow": true,
            "aps-environment": "development",
        ]
        let result = SigningPlanner.entitlements(
            fromProfileEntitlements: source,
            applicationIdentifier: "ABCDE12345.com.example.app",
            teamIdentifier: "ABCDE12345"
        )
        XCTAssertEqual(result["application-identifier"] as? String, "ABCDE12345.com.example.app")
        XCTAssertEqual(result["keychain-access-groups"] as? [String], ["ABCDE12345.com.example.app", "com.apple.token"])
        XCTAssertNil(result["com.apple.developer.associated-domains"])
        XCTAssertEqual(result["get-task-allow"] as? Bool, true)
        XCTAssertEqual(result["aps-environment"] as? String, "development")
        XCTAssertEqual(result["com.apple.developer.team-identifier"] as? String, "ABCDE12345")
    }
}

final class IPAInspectorTests: XCTestCase {
    func testFindsNestedExtensions() {
        let paths: Set<String> = [
            "Payload/A.app/Info.plist",
            "Payload/A.app/PlugIns/Widget.appex/Info.plist",
            "Payload/A.app/PlugIns/Widget.appex/Widget",
            "Payload/A.app/Watch/W.app/Info.plist",
            "Payload/A.app/Watch/W.app/PlugIns/Complication.appex/Info.plist",
            "Payload/A.app/Frameworks/Lib.framework/Info.plist",
        ]
        XCTAssertEqual(IPAInspector.extensionRoots(in: paths, under: "Payload/A.app/"), [
            "Payload/A.app/PlugIns/Widget.appex/",
            "Payload/A.app/Watch/W.app/PlugIns/Complication.appex/",
        ])
    }
}

enum TestData {
    static func profileBlob(devices: [String]?, getTaskAllow: Bool = false, allDevices: Bool = false) throws -> Data {
        var plist: [String: Any] = [
            "Name": "Test Ad Hoc",
            "TeamIdentifier": ["ABCDE12345"],
            "TeamName": "Test Team",
            "ExpirationDate": Date().addingTimeInterval(365 * 24 * 3600),
            "Entitlements": ["application-identifier": "ABCDE12345.com.example.app", "get-task-allow": getTaskAllow],
        ]
        if let devices { plist["ProvisionedDevices"] = devices }
        if allDevices { plist["ProvisionsAllDevices"] = true }
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return Data([0x30, 0x80, 0x06, 0x09]) + xml + Data([0xA0, 0x82, 0x00, 0x00])
    }

    static func package() throws -> AppPackage {
        let profile = try ProvisioningProfile.parse(profileBlob(devices: ["abc"]))
        let container = BundleInfo(
            path: "Payload/Host.app/",
            plist: ["CFBundleIdentifier": "com.example.app", "CFBundleShortVersionString": "1.0", "DTPlatformName": "iphoneos", "UIDeviceFamily": [1]],
            hasCodeSignature: true,
            profile: profile
        )
        let watch = BundleInfo(
            path: "Payload/Host.app/Watch/Face.app/",
            plist: ["CFBundleIdentifier": "com.example.app.watchkitapp", "DTPlatformName": "watchos", "UIDeviceFamily": [4],
                    "WKApplication": true, "WKCompanionAppBundleIdentifier": "com.example.app"],
            hasCodeSignature: true,
            profile: profile
        )
        return AppPackage(id: UUID(), storedFileName: "x.ipa", originalFileName: "x.ipa", importedAt: Date(),
                          fileSize: 1, container: container, watchApps: [watch])
    }
}
