import Foundation

// MARK: - 当前版本
enum AppVersion {
    /// 取自 Info.plist 的 CFBundleShortVersionString，与打包出的 DMG 一致
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

// MARK: - 版本比较
//
// 与网络无关的纯逻辑，便于验证版本号高低的判断。
enum VersionCheck {
    enum Outcome: Equatable {
        /// 已是最新
        case upToDate
        /// 有更新的版本
        case updateAvailable(latest: String)
        /// 查不到（网络问题或返回内容不可解析）
        case failed
    }

    /// 把 "v1.2.3"、"1.2.3"、"1.2.3-beta.1" 拆成可比较的数字。
    /// 前导 v 与预发布后缀都不参与比较，解析不出的段按 0 处理。
    static func components(_ raw: String) -> [Int] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let dash = text.firstIndex(of: "-") { text = String(text[text.startIndex ..< dash]) }
        guard !text.isEmpty else { return [] }
        return text.split(separator: ".").map { part in
            Int(part.prefix(while: { $0.isNumber })) ?? 0
        }
    }

    /// candidate 是否比 current 新。逐段比较、缺的段补 0，所以 1.2 与 1.2.0 视为相同。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = components(candidate)
        let currentParts = components(current)
        guard !candidateParts.isEmpty, !currentParts.isEmpty else { return false }

        for index in 0 ..< max(candidateParts.count, currentParts.count) {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    /// 拿到最新 tag 之后该给用户看什么
    static func outcome(current: String, latestTag: String?) -> Outcome {
        guard let tag = latestTag, !components(tag).isEmpty else { return .failed }
        return isNewer(tag, than: current) ? .updateAvailable(latest: display(tag)) : .upToDate
    }

    /// 显示用的版本号，去掉 tag 的 v 前缀
    static func display(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text
    }
}

// MARK: - 查询最新版本
enum UpdateChecker {
    /// 官方下载页
    static let downloadPage = URL(string: "https://elysia.macwave.org/Downloads/")!

    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/Sha0huaZhang/Elysia/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
    }

    /// 向 GitHub 询问最新 release 的 tag。失败时抛出，由调用方显示「查询失败」。
    static func latestTag() async throws -> String {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Release.self, from: data).tag_name
    }
}
