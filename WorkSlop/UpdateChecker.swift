import SwiftUI

/// Real GitHub update checker. On launch it asks the GitHub API for the
/// latest release of adnan120hz/WorkSlop-Mobile-New and compares the tag
/// against this build's CFBundleShortVersionString. If the tag is newer,
/// the app shows a "New update" popup with a button to the release page.
///
/// Honest behavior: no releases yet (API 404) = silence, never an error
/// popup. Network failure = silence. A version is only announced once.
final class UpdateChecker: ObservableObject {
    struct Update: Identifiable {
        let id = UUID()
        let version: String
        let url: URL
        let notes: String
    }

    @Published var available: Update?

    private static let repo = "adnan120hz/WorkSlop-Mobile-New"
    private static let seenKey = "updateSeenVersion"

    /// Current app version, e.g. "15.0".
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Compare "15.0" vs "v15.1" numerically. Returns true if `latest`
    /// is strictly newer than `current`.
    static func isNewer(latest: String, current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let l = parts(latest), c = parts(current)
        for i in 0..<max(l.count, c.count) {
            let li = i < l.count ? l[i] : 0
            let ci = i < c.count ? c[i] : 0
            if li != ci { return li > ci }
        }
        return false
    }

    @MainActor
    func check() async {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("WorkSlop-Mobile", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              Self.isNewer(latest: tag, current: Self.currentVersion)
        else { return } // no releases / network issue / not newer = stay silent

        let seen = UserDefaults.standard.string(forKey: Self.seenKey)
        guard seen != tag else { return } // already announced this version
        UserDefaults.standard.set(tag, forKey: Self.seenKey)

        let notes = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(Self.repo)/releases")!
        available = Update(version: tag, url: page,
                           notes: String(notes.prefix(300)))
    }
}
