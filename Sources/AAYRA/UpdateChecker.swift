import Foundation
import Observation

/// Lightweight "new version available" check against the latest GitHub Release.
///
/// Off by default: nothing is sent unless the user turns on automatic checks or clicks Check Now.
/// A check is one HTTPS request to GitHub's public API (no account, no identifiers). It never
/// downloads or installs anything; it only says a newer version exists and links to its release page.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case noReleases  // the repo hasn't published a release yet
        case available(version: String, url: URL)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastChecked: Date?

    /// The newer version found by the last check, if any (also remembered between launches).
    var availableUpdate: (version: String, url: URL)? {
        if case .available(let version, let url) = status { return (version, url) }
        return nil
    }

    private static let api = URL(string: "https://api.github.com/repos/nullifye/AAYRA-System-Monitor/releases/latest")!
    private static let checkEvery: TimeInterval = 24 * 60 * 60
    private var loop: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        lastChecked = defaults.object(forKey: AppSettings.Key.lastUpdateCheck) as? Date
        // Keep showing an update found earlier, as long as it's still newer than this build.
        if let version = defaults.string(forKey: AppSettings.Key.latestKnownVersion),
            let link = defaults.string(forKey: AppSettings.Key.latestKnownURL), let url = URL(string: link),
            Self.isVersion(version, newerThan: AppInfo.version)
        {
            status = .available(version: version, url: url)
        }
    }

    /// Checks once a day while automatic checks are on. Turning the setting on checks right away.
    func startAutomaticChecks() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))  // let the app settle after launch
            while !Task.isCancelled {
                if let self, AppSettings.checkForUpdates,
                    Date().timeIntervalSince(self.lastChecked ?? .distantPast) >= Self.checkEvery
                {
                    await self.check()
                }
                try? await Task.sleep(for: .seconds(60 * 60))  // re-evaluate hourly
            }
        }
    }

    func checkNow() {
        Task { await check() }
    }

    private func check() async {
        guard status != .checking else { return }
        let previous = status
        status = .checking
        var request = URLRequest(url: Self.api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AAYRA/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")  // GitHub asks for one

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            record(checkedAt: Date())
            switch code {
            case 200:
                let release = try JSONDecoder().decode(Release.self, from: data)
                let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if Self.isVersion(version, newerThan: AppInfo.version) {
                    status = .available(version: version, url: release.htmlURL)
                    remember(version: version, url: release.htmlURL)
                } else {
                    status = .upToDate
                    remember(version: nil, url: nil)
                }
            case 404:
                status = .noReleases
            case 403, 429:
                status = .failed("GitHub is limiting requests. Try again later.")
            default:
                status = .failed("GitHub returned an error (\(code)).")
            }
        } catch is DecodingError {
            status = .failed("Couldn't read GitHub's reply.")
        } catch {
            // Offline or similar: keep a previously found update visible.
            if case .available = previous { status = previous } else { status = .failed("Couldn't reach GitHub.") }
        }
    }

    private func record(checkedAt date: Date) {
        lastChecked = date
        UserDefaults.standard.set(date, forKey: AppSettings.Key.lastUpdateCheck)
    }

    private func remember(version: String?, url: URL?) {
        let defaults = UserDefaults.standard
        defaults.set(version, forKey: AppSettings.Key.latestKnownVersion)
        defaults.set(url?.absoluteString, forKey: AppSettings.Key.latestKnownURL)
    }

    /// Compares dotted versions numerically: "1.10" is newer than "1.9", "1.3.1" newer than "1.3".
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
