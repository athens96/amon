import Foundation
import os

// openusage(robinebers/openusage, MIT © 2026 Robin Ebers)의 프로바이더 파이프라인을
// A-mon 에 이식하면서, 원본의 횡단 관심사(로깅·리댁션·프록시)를 얇은 shim 으로 대체한다.
// 프로바이더/서비스 코드는 원본을 최대한 그대로 두고, 여기서 요구하는 심볼만 채운다.

/// 로그 태그 — 원본 `LogTag` 대체. 민감정보(토큰/헤더/바디)는 절대 로깅하지 않는 원본 규칙을
/// 그대로 유지하기 위해, 실제 출력도 카테고리·메시지 수준으로만 남긴다.
struct LogTag: Sendable {
    let category: String
    static let http = LogTag(category: "http")
    static let auth = LogTag(category: "auth")
    static let keychain = LogTag(category: "keychain")
    static let subprocess = LogTag(category: "subprocess")
    static let config = LogTag(category: "config")
    /// 프로바이더별 auth 태그 (예: `auth("claude")`).
    static func auth(_ id: String) -> LogTag { LogTag(category: "auth.\(id)") }
}

/// 경량 로거 — 원본 `AppLog` 대체. os.Logger 로 흘리되 기본 레벨은 debug 이므로 릴리즈에서 조용하다.
enum AppLog {
    private static func log(_ tag: LogTag, _ level: OSLogType, _ message: String) {
        Logger(subsystem: "com.athens96.amon.providers", category: tag.category).log(level: level, "\(message, privacy: .public)")
    }
    static func debug(_ tag: LogTag, _ message: @autoclosure () -> String) { log(tag, .debug, message()) }
    static func info(_ tag: LogTag, _ message: @autoclosure () -> String) { log(tag, .info, message()) }
    static func warn(_ tag: LogTag, _ message: @autoclosure () -> String) { log(tag, .default, message()) }
    static func error(_ tag: LogTag, _ message: @autoclosure () -> String) { log(tag, .error, message()) }
}
