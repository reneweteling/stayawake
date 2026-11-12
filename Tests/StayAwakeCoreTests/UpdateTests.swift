import XCTest
@testable import StayAwakeCore

final class UpdateTests: XCTestCase {
    // MARK: - Version comparison

    func testNewerPatchMinorAndMajor() {
        XCTAssertEqual(UpdatePolicy.compare("v1.4.1", "1.4.0"), .orderedDescending)
        XCTAssertEqual(UpdatePolicy.compare("1.5.0", "1.4.9"), .orderedDescending)
        XCTAssertEqual(UpdatePolicy.compare("2.0.0", "1.99.99"), .orderedDescending)
        XCTAssertEqual(UpdatePolicy.compare("1.4.0", "v1.4.1"), .orderedAscending)
    }

    func testComparesNumbersNotText() {
        XCTAssertEqual(UpdatePolicy.compare("1.10.0", "1.9.0"), .orderedDescending)
    }

    func testPrefixAndMissingPartsAreEqual() {
        XCTAssertEqual(UpdatePolicy.compare("v1.4.0", "1.4.0"), .orderedSame)
        XCTAssertEqual(UpdatePolicy.compare("1.4", "1.4.0"), .orderedSame)
        XCTAssertEqual(UpdatePolicy.compare("2", "2.0.0"), .orderedSame)
    }

    func testSuffixIsIgnored() {
        XCTAssertEqual(UpdatePolicy.compare("1.5.0-beta.1", "1.5.0"), .orderedSame)
        XCTAssertEqual(UpdatePolicy.compare("1.5.0+abc", "1.4.9"), .orderedDescending)
    }

    func testDevBuildCountsAsOldest() {
        XCTAssertEqual(UpdatePolicy.compare("v1.4.1", "dev"), .orderedDescending)
    }

    func testDisplayVersionDropsThePrefix() {
        XCTAssertEqual(UpdatePolicy.displayVersion("v1.4.1"), "1.4.1")
        XCTAssertEqual(UpdatePolicy.displayVersion("1.4.1"), "1.4.1")
    }

    // MARK: - Release parsing

    let sample = """
    {
      "tag_name": "v1.4.1",
      "html_url": "https://github.com/reneweteling/stayawake/releases/tag/v1.4.1",
      "draft": false,
      "prerelease": false,
      "assets": [
        {
          "name": "StayAwake.dmg",
          "label": "StayAwake v1.4.1 for macOS (Apple Silicon)",
          "size": 2629290,
          "digest": "sha256:6b77831ac02944ced7bc94120fce2853b23a7968f9499ab2b3fdf4a8a4bbfb58",
          "browser_download_url": "https://github.com/reneweteling/stayawake/releases/download/v1.4.1/StayAwake.dmg"
        }
      ]
    }
    """

    func testParsesTheReleaseAndItsDMG() throws {
        let release = try ReleaseInfo.parse(Data(sample.utf8))
        XCTAssertEqual(release.tagName, "v1.4.1")
        XCTAssertEqual(release.htmlURL?.absoluteString, "https://github.com/reneweteling/stayawake/releases/tag/v1.4.1")
        let dmg = try XCTUnwrap(release.dmgAsset)
        XCTAssertEqual(dmg.name, "StayAwake.dmg")
        XCTAssertEqual(dmg.size, 2629290)
        XCTAssertEqual(dmg.sha256, "6b77831ac02944ced7bc94120fce2853b23a7968f9499ab2b3fdf4a8a4bbfb58")
        XCTAssertEqual(dmg.downloadURL.absoluteString,
                       "https://github.com/reneweteling/stayawake/releases/download/v1.4.1/StayAwake.dmg")
    }

    func testBrokenJSONIsAParseError() {
        XCTAssertThrowsError(try ReleaseInfo.parse(Data("{\"message\":\"Not Found\"}".utf8)))
        XCTAssertThrowsError(try ReleaseInfo.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try ReleaseInfo.parse(Data("{\"tag_name\":\"  \"}".utf8)))
    }

    func testReleaseWithoutAssetsHasNoDMG() throws {
        let release = try ReleaseInfo.parse(Data("{\"tag_name\":\"v1.5.0\"}".utf8))
        XCTAssertNil(release.dmgAsset)
        XCTAssertNil(release.htmlURL)
    }

    func testDMGFromAnotherRepoOrHostIsIgnored() throws {
        let json = """
        {"tag_name":"v1.5.0","assets":[
          {"name":"StayAwake.dmg","browser_download_url":"https://github.com/someone/else/releases/download/v1.5.0/StayAwake.dmg"},
          {"name":"StayAwake.dmg","browser_download_url":"http://github.com/reneweteling/stayawake/releases/download/v1.5.0/StayAwake.dmg"},
          {"name":"notes.txt","browser_download_url":"https://github.com/reneweteling/stayawake/releases/download/v1.5.0/notes.txt"}
        ]}
        """
        XCTAssertNil(try ReleaseInfo.parse(Data(json.utf8)).dmgAsset)
    }

    func testStayAwakeDMGWinsOverOtherDMGs() throws {
        let json = """
        {"tag_name":"v1.5.0","assets":[
          {"name":"Other.dmg","browser_download_url":"https://github.com/reneweteling/stayawake/releases/download/v1.5.0/Other.dmg"},
          {"name":"StayAwake.dmg","browser_download_url":"https://github.com/reneweteling/stayawake/releases/download/v1.5.0/StayAwake.dmg"}
        ]}
        """
        XCTAssertEqual(try ReleaseInfo.parse(Data(json.utf8)).dmgAsset?.name, "StayAwake.dmg")
    }

    func testPrereleaseIsNotInstalled() throws {
        let json = """
        {"tag_name":"v1.5.0","prerelease":true,"assets":[
          {"name":"StayAwake.dmg","browser_download_url":"https://github.com/reneweteling/stayawake/releases/download/v1.5.0/StayAwake.dmg"}
        ]}
        """
        XCTAssertNil(try ReleaseInfo.parse(Data(json.utf8)).dmgAsset)
    }

    func testDigestParsing() {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(ReleaseInfo.sha256(fromDigest: "sha256:\(hex.uppercased())"), hex)
        XCTAssertNil(ReleaseInfo.sha256(fromDigest: "sha512:\(hex)"))
        XCTAssertNil(ReleaseInfo.sha256(fromDigest: "sha256:abc"))
        XCTAssertNil(ReleaseInfo.sha256(fromDigest: "sha256:" + String(repeating: "zz", count: 32)))
        XCTAssertNil(ReleaseInfo.sha256(fromDigest: nil))
    }

    // MARK: - Verdict

    func testNewerReleaseIsAvailableWithItsDMG() throws {
        let release = try ReleaseInfo.parse(Data(sample.utf8))
        guard case let .available(version, page, download) = UpdatePolicy.verdict(currentVersion: "1.4.0", release: release) else {
            return XCTFail("expected an update")
        }
        XCTAssertEqual(version, "1.4.1")
        XCTAssertEqual(page, release.htmlURL)
        XCTAssertEqual(download?.name, "StayAwake.dmg")
    }

    func testSameOrOlderReleaseIsUpToDate() throws {
        let release = try ReleaseInfo.parse(Data(sample.utf8))
        XCTAssertEqual(UpdatePolicy.verdict(currentVersion: "1.4.1", release: release), .upToDate(latest: "1.4.1"))
        XCTAssertEqual(UpdatePolicy.verdict(currentVersion: "1.5.0", release: release), .upToDate(latest: "1.4.1"))
    }

    func testAvailableWithoutPageFallsBackToReleasesPage() throws {
        let release = try ReleaseInfo.parse(Data("{\"tag_name\":\"v9.0.0\"}".utf8))
        XCTAssertEqual(UpdatePolicy.verdict(currentVersion: "1.4.0", release: release),
                       .available(version: "9.0.0", page: UpdatePolicy.releasesPageURL, download: nil))
    }

    // MARK: - Cadence

    func testCheckCadence() {
        let now = iso("2026-11-12T12:00:00Z")
        XCTAssertTrue(UpdatePolicy.shouldCheck(checkedThisProcess: false, lastCheck: now, now: now))
        XCTAssertTrue(UpdatePolicy.shouldCheck(checkedThisProcess: true, lastCheck: nil, now: now))
        XCTAssertFalse(UpdatePolicy.shouldCheck(checkedThisProcess: true, lastCheck: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(UpdatePolicy.shouldCheck(checkedThisProcess: true, lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertTrue(UpdatePolicy.shouldCheck(checkedThisProcess: true, lastCheck: now.addingTimeInterval(3600), now: now))
    }

    func testRequestsGoToThePublicAPIOnly() {
        XCTAssertEqual(UpdatePolicy.latestReleaseURL.absoluteString,
                       "https://api.github.com/repos/reneweteling/stayawake/releases/latest")
        XCTAssertFalse(UpdatePolicy.userAgent.contains("@"))
    }
}
