import Foundation

/// The pure half of the updater: which release is newer, which asset to
/// download and when to ask GitHub again. Same approach as TidyDrive: the
/// public `releases/latest` endpoint and the DMG attached to that release.
public enum UpdatePolicy {
    public static let repo = "reneweteling/stayawake"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    public static let releasesPageURL = URL(string: "https://github.com/\(repo)/releases/latest")!
    /// Asset downloads must come from this repo's release downloads.
    public static let downloadPrefix = "https://github.com/\(repo)/releases/download/"
    /// No name, no machine id: GitHub only needs some User-Agent.
    public static let userAgent = "StayAwake-Updater"
    /// Ask GitHub at most once a day, like TidyDrive. Launch always asks.
    public static let minCheckInterval: TimeInterval = 24 * 3600
    /// How often the app looks whether a check is due.
    public static let timerInterval: TimeInterval = 3 * 3600

    /// "v1.4.1" and "1.4.1" compare equal. Missing parts count as 0, a
    /// pre-release or build suffix ("-beta.1", "+abc") is ignored.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let ac = components(a)
        let bc = components(b)
        for i in 0..<max(ac.count, bc.count) {
            let x = i < ac.count ? ac[i] : 0
            let y = i < bc.count ? bc[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    /// "v1.4.1" becomes "1.4.1".
    public static func displayVersion(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("v") || t.hasPrefix("V") ? String(t.dropFirst()) : t
    }

    static func components(_ version: String) -> [Int] {
        let core = displayVersion(version).split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        var parts = core.split(separator: ".").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        return parts
    }

    /// Launch always checks once; after that only when a day has passed.
    public static func shouldCheck(checkedThisProcess: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard checkedThisProcess, let lastCheck else { return true }
        // A clock that went backwards should not block checks for a day.
        if now < lastCheck { return true }
        return now.timeIntervalSince(lastCheck) >= minCheckInterval
    }

    /// What a check found.
    public enum Verdict: Equatable, Sendable {
        case upToDate(latest: String)
        /// `download` is nil when the release has no usable DMG; the user
        /// then gets the release page instead of an install button.
        case available(version: String, page: URL, download: ReleaseInfo.Asset?)
    }

    public static func verdict(currentVersion: String, release: ReleaseInfo) -> Verdict {
        let latest = displayVersion(release.tagName)
        guard compare(release.tagName, currentVersion) == .orderedDescending else { return .upToDate(latest: latest) }
        return .available(version: latest, page: release.htmlURL ?? releasesPageURL, download: release.dmgAsset)
    }
}

/// The parts of a GitHub release the updater reads.
public struct ReleaseInfo: Equatable, Sendable {
    public struct Asset: Equatable, Sendable {
        public var name: String
        public var downloadURL: URL
        public var size: Int?
        /// Lowercase hex SHA-256 from GitHub's `digest` field, when present.
        public var sha256: String?
    }

    public var tagName: String
    public var htmlURL: URL?
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [Asset]

    public struct ParseError: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    private struct Raw: Decodable {
        let tag_name: String
        let html_url: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [RawAsset]?
        struct RawAsset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int?
            let digest: String?
        }
    }

    public static func parse(_ data: Data) throws -> ReleaseInfo {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw ParseError(message: "GitHub sent a release the app cannot read")
        }
        let tag = raw.tag_name.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { throw ParseError(message: "The release has no version") }
        let assets: [Asset] = (raw.assets ?? []).compactMap { a in
            guard let url = URL(string: a.browser_download_url) else { return nil }
            return Asset(name: a.name, downloadURL: url, size: a.size, sha256: sha256(fromDigest: a.digest))
        }
        return ReleaseInfo(tagName: tag, htmlURL: raw.html_url.flatMap(URL.init(string:)),
                           draft: raw.draft ?? false, prerelease: raw.prerelease ?? false, assets: assets)
    }

    /// The DMG to install: one ending in .dmg that lives under this repo's
    /// release downloads over https. "StayAwake.dmg" wins over other names.
    public var dmgAsset: Asset? {
        guard !draft, !prerelease else { return nil }
        let candidates = assets.filter { asset in
            asset.name.lowercased().hasSuffix(".dmg")
                && asset.downloadURL.absoluteString.hasPrefix(UpdatePolicy.downloadPrefix)
        }
        return candidates.first { $0.name == "StayAwake.dmg" } ?? candidates.first
    }

    /// "sha256:<64 hex>" becomes the hex. Anything else is nil.
    static func sha256(fromDigest digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return String(hex)
    }
}
