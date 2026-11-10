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

    func testMissingWatchAppIsError() throws {
        var package = try TestData.package()
        package.watchApps = []
        XCTAssertFalse(package.canInstall)
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
