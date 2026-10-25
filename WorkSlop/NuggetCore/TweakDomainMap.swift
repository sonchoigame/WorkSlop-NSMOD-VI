import Foundation

// VERBATIM PORT from GoldenNugget-mobile (Nugget/Core/TweakDomainMap.swift)
// https://github.com/goldennugget-team/goldennugget-mobile
// Source: GoldenNugget's src/restore/path_mapping.py.

/// Absolute device path → backup domain.
enum TweakDomainMap {
    private struct Rule {
        let prefix: String
        let domain: String
        let isContainer: Bool
    }

    /// Order is load-bearing: first match wins, `/var/Managed Preferences/`
    /// must be reached before a looser prefix could shadow it.
    private static let rules: [Rule] = [
        Rule(prefix: "/var/Managed Preferences/", domain: "ManagedPreferencesDomain", isContainer: false),
        Rule(prefix: "/var/root/", domain: "RootDomain", isContainer: false),
        Rule(prefix: "/var/preferences/", domain: "SystemPreferencesDomain", isContainer: false),
        Rule(prefix: "/var/MobileDevice/", domain: "MobileDeviceDomain", isContainer: false),
        Rule(prefix: "/var/mobile/", domain: "HomeDomain", isContainer: false),
        Rule(prefix: "/var/db/", domain: "DatabaseDomain", isContainer: false),
        Rule(prefix: "/var/containers/Shared/SystemGroup/",
             domain: "SysSharedContainerDomain-", isContainer: true),
        Rule(prefix: "/var/containers/Data/SystemGroup/",
             domain: "SysContainerDomain-", isContainer: true),
    ]

    struct Destination: Equatable, Sendable {
        let domain: String
        let relativePath: String
    }

    /// `split_path_into_domain`. Returns nil when no prefix matches.
    static func split(path: String) -> Destination? {
        for rule in rules where path.hasPrefix(rule.prefix) {
            let rest = String(path.dropFirst(rule.prefix.count))
            guard rule.isContainer else {
                return Destination(domain: rule.domain, relativePath: rest)
            }
            if let slash = rest.firstIndex(of: "/") {
                let group = String(rest[rest.startIndex..<slash])
                let remainder = String(rest[rest.index(after: slash)...])
                return Destination(domain: rule.domain + group, relativePath: remainder)
            }
            return Destination(domain: rule.domain + rest, relativePath: "")
        }
        return nil
    }
}
