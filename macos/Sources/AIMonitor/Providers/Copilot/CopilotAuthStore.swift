import Foundation

/// A GitHub token already on the machine, usable against the Copilot usage endpoint.
struct CopilotToken: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        /// The OAuth token written by the Copilot editor plugins (VS Code / JetBrains / Neovim).
        case editorApp
        /// `oauth_token` stored in the GitHub CLI's `hosts.yml` (file-based storage).
        case ghConfig
        /// The GitHub CLI token stored in the macOS Keychain via go-keyring.
        case ghKeychain
    }

    var value: String
    var source: Source
}

enum CopilotAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case tokenInvalid

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in to GitHub Copilot in your editor, or run gh auth login, and try again."
        case .tokenInvalid:
            return "GitHub token invalid or expired. Re-authenticate (gh auth login) and try again."
        }
    }
}

/// Reads a GitHub token that Copilot tooling already left on the machine — no login flow, no browser
/// cookies. Sources are tried prompt-free files first, Keychain last:
/// 1. Copilot editor config `~/.config/github-copilot/apps.json` (older `hosts.json`) — the OAuth token
///    the VS Code / JetBrains / Neovim Copilot plugins write. Universal and file-based.
/// 2. GitHub CLI `~/.config/gh/hosts.yml` `oauth_token` — present when `gh` stores the token in a file.
/// 3. GitHub CLI Keychain item (service `gh:github.com`) — go-keyring-wrapped, used when `gh` stores the
///    token in the system keyring instead of the file.
struct CopilotAuthStore: Sendable {
    static let editorAppsPath = "~/.config/github-copilot/apps.json"
    static let editorHostsPath = "~/.config/github-copilot/hosts.json"
    static let ghHostsPath = "~/.config/gh/hosts.yml"
    static let ghKeychainService = "gh:github.com"

    var files: TextFileAccessing
    var keychain: KeychainAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor()
    ) {
        self.files = files
        self.keychain = keychain
    }

    /// First non-empty source wins. Blocking (Keychain) — call off the main actor.
    func loadToken() -> CopilotToken? {
        loadFromEditorConfig() ?? loadFromGhConfig() ?? loadFromGhKeychain()
    }

    /// 모든 후보 토큰 — 에디터 설정(apps.json)의 `github.com*` 항목 전부, 이어서
    /// gh 파일·Keychain. apps.json 에는 구/신 Copilot 앱 항목이 공존할 수 있고
    /// 그중 일부는 만료 상태라, 호출부가 순서대로 시도해 살아있는 토큰을 찾는다.
    /// Blocking (Keychain) — call off the main actor.
    func loadTokenCandidates() -> [CopilotToken] {
        var out: [CopilotToken] = []
        var seen = Set<String>()
        func add(_ candidate: CopilotToken?) {
            guard let candidate, !seen.contains(candidate.value) else { return }
            seen.insert(candidate.value)
            out.append(candidate)
        }
        for path in [Self.editorAppsPath, Self.editorHostsPath] {
            guard files.exists(path), let text = try? files.readText(path) else { continue }
            for token in Self.oauthTokens(fromEditorJSON: text) {
                add(CopilotToken(value: token, source: .editorApp))
            }
        }
        add(loadFromGhConfig())
        add(loadFromGhKeychain())
        return out
    }

    // MARK: - Sources

    func loadFromEditorConfig() -> CopilotToken? {
        for path in [Self.editorAppsPath, Self.editorHostsPath] {
            guard files.exists(path),
                  let text = try? files.readText(path),
                  let token = Self.oauthToken(fromEditorJSON: text)
            else {
                continue
            }
            return CopilotToken(value: token, source: .editorApp)
        }
        return nil
    }

    func loadFromGhConfig() -> CopilotToken? {
        guard files.exists(Self.ghHostsPath),
              let text = try? files.readText(Self.ghHostsPath),
              let token = Self.yamlValue(text, key: "oauth_token")
        else {
            return nil
        }
        return CopilotToken(value: token, source: .ghConfig)
    }

    func loadFromGhKeychain() -> CopilotToken? {
        guard let raw = readGhKeychainRaw(),
              let token = Self.unwrapGoKeyring(raw)
        else {
            return nil
        }
        return CopilotToken(value: token, source: .ghKeychain)
    }

    private func readGhKeychainRaw() -> String? {
        // `gh` stores its Keychain item under the GitHub username as the account. Read it scoped to that
        // account when we can recover it from hosts.yml; otherwise fall back to a service-only lookup.
        if let account = ghUsername(),
           let raw = try? keychain.readGenericPassword(service: Self.ghKeychainService, account: account) {
            return raw
        }
        return try? keychain.readGenericPassword(service: Self.ghKeychainService)
    }

    private func ghUsername() -> String? {
        guard files.exists(Self.ghHostsPath),
              let text = try? files.readText(Self.ghHostsPath)
        else {
            return nil
        }
        return Self.yamlValue(text, key: "user")
    }

    // MARK: - Parsing (pure)

    /// Pull a github.com `oauth_token` from the Copilot editor config. The file is a JSON object keyed by
    /// host — `"github.com"` (older `hosts.json`) or `"github.com:<appId>"` (newer `apps.json`) — each
    /// value an object carrying `oauth_token`. Only github.com entries are used: another host's token
    /// (e.g. GitHub Enterprise) must not be sent to api.github.com, and returning `nil` lets the chain
    /// fall through to gh config / keychain, which may hold a valid github.com token.
    static func oauthToken(fromEditorJSON text: String) -> String? {
        oauthTokens(fromEditorJSON: text).first
    }

    /// apps.json 의 `github.com*` 항목 전체에서 토큰을 모은다. Dictionary 순회는
    /// 프로세스마다 순서가 달라지므로 키 내림차순으로 고정한다 — GitHub 앱 ID 가
    /// 새 형식(Iv23…)일수록 사전순으로 뒤라, 내림차순이 신규 앱 항목을 앞세운다.
    static func oauthTokens(fromEditorJSON text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }
        return oauthTokensIn(object)
    }

    private static func oauthTokensIn(_ object: [String: Any]) -> [String] {
        object.keys
            .filter { $0 == "github.com" || $0.hasPrefix("github.com:") }
            .sorted(by: >)
            .compactMap { key in
                guard let dict = object[key] as? [String: Any],
                      let token = (dict["oauth_token"] as? String)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty
                else { return nil }
                return token
            }
    }

    /// Read an indented `key: value` from within a specific host block of the `hosts.yml` GitHub CLI
    /// writes. `gh` keys each host block by a top-level (unindented) `<host>:` line; reading must be
    /// scoped to the `github.com` block, because a GitHub Enterprise block in the same file would
    /// otherwise let its `oauth_token` win and get sent to api.github.com (a guaranteed 401/403).
    /// `users:` (the nested map) doesn't match `user:` because the colon position differs.
    static func yamlValue(_ text: String, key: String, host: String = "github.com") -> String? {
        let prefix = key + ":"
        let hostHeader = host + ":"
        var inHost = false
        for line in text.split(whereSeparator: \.isNewline) {
            // An unindented line starts a new top-level block (a host header or other root key); only
            // the github.com block's children should be read.
            if let first = line.first, !first.isWhitespace {
                inHost = line.trimmingCharacters(in: .whitespaces).hasPrefix(hostHeader)
                continue
            }
            guard inHost else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

    /// Unwrap a `go-keyring-base64:`-prefixed value (how `gh` stores its token in the macOS Keychain),
    /// returning the decoded token. A value without the prefix is returned trimmed as-is.
    static func unwrapGoKeyring(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            let encoded = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.nilIfEmpty
    }
}
