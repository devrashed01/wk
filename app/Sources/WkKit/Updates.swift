import Foundation

/// Asks GitHub for the newest release tag; nothing about this Mac is sent beyond the request itself.
public enum Updates {
    public static let releasesPage = URL(string: "https://github.com/devrashed01/wk/releases/latest")!
    public static let installCommand = "curl -fsSL https://raw.githubusercontent.com/devrashed01/wk/main/install.sh | sh"

    public static func latestVersion() async -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/devrashed01/wk/releases/latest")!)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        struct Release: Decodable { var tag_name: String }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        return release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
    }

    /// True when `candidate` is a higher dotted version than `current` ("0.2.10" > "0.2.9").
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts: (String) -> [Int] = { $0.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0, right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
