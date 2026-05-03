//
//  UpdateChecker.swift
//  speakertpyer
//
//  輕量更新檢查：呼叫 GitHub Releases API 取最新版號比對 Bundle 版本。
//  無外部依賴（不引入 Sparkle / SPM）。
//

import Foundation

actor UpdateChecker {
    static let shared = UpdateChecker()

    /// GitHub repo (owner/name)。
    private let repo = "Oliver0804/Saybit"

    struct ReleaseInfo: Decodable {
        let tagName: String        // e.g. "v1.5.0" or "1.5.0"
        let name: String?
        let htmlUrl: String
        let body: String?
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlUrl = "html_url"
            case body
            case prerelease
        }
    }

    enum CheckResult {
        case upToDate(current: String)
        case newer(current: String, latest: ReleaseInfo)
        case ahead(current: String, latest: String) // local > remote (dev build)
    }

    enum CheckError: LocalizedError {
        case network(Error)
        case http(Int)
        case decode(Error)
        case noRelease

        var errorDescription: String? {
            switch self {
            case .network(let e): return "更新檢查網路錯誤：\(e.localizedDescription)"
            case .http(let c):    return "更新檢查 HTTP \(c)"
            case .decode(let e):  return "更新資訊解析失敗：\(e.localizedDescription)"
            case .noRelease:      return "GitHub 上尚無 release"
            }
        }
    }

    /// 抓取最新 release。
    func fetchLatestRelease() async throws -> ReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw CheckError.noRelease
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Saybit-UpdateChecker", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 404 { throw CheckError.noRelease }
            guard (200...299).contains(status) else { throw CheckError.http(status) }
            do {
                return try JSONDecoder().decode(ReleaseInfo.self, from: data)
            } catch {
                throw CheckError.decode(error)
            }
        } catch let e as CheckError {
            throw e
        } catch {
            throw CheckError.network(error)
        }
    }

    /// 跟目前 bundle 版本比較。
    func check() async throws -> CheckResult {
        let current = currentVersion()
        let latest = try await fetchLatestRelease()
        let latestVersion = Self.normalize(latest.tagName)
        let order = Self.compareSemver(current, latestVersion)
        if order == .orderedAscending {
            return .newer(current: current, latest: latest)
        } else if order == .orderedDescending {
            return .ahead(current: current, latest: latestVersion)
        } else {
            return .upToDate(current: current)
        }
    }

    // MARK: - Helpers

    nonisolated func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// "v1.5.0" → "1.5.0"，去掉 leading 'v'。
    static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        return s
    }

    /// Semver 比較（只比 major.minor.patch，pre-release 後綴忽略）。
    static func compareSemver(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lParts = parts(lhs)
        let rParts = parts(rhs)
        let count = max(lParts.count, rParts.count)
        for i in 0..<count {
            let a = i < lParts.count ? lParts[i] : 0
            let b = i < rParts.count ? rParts[i] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func parts(_ s: String) -> [Int] {
        // 取主版號段（去掉 "-beta.1" 之類）
        let core = s.split(separator: "-").first.map(String.init) ?? s
        return core.split(separator: ".").compactMap { Int($0) }
    }
}
