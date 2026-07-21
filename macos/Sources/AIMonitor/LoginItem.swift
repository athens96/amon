import Foundation
import ServiceManagement

/// "로그인 시 자동 실행" — macOS 13+ 표준 `SMAppService.mainApp` 로 등록/해제.
///
/// 시스템 설정 → 일반 → 로그인 항목에 이 앱을 추가한다. 상태의 단일 출처는
/// 시스템(`SMAppService`)이므로 UserDefaults 로 따로 저장하지 않는다.
/// 번들(.app)로 실행할 때만 동작한다 (`swift run` 처럼 번들 없이 실행 시 실패).
enum LoginItem {
    /// 현재 로그인 실행이 켜져 있는지.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 로그인 실행을 켜거나 끈다. 실패 시 throw.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else {
            if service.status == .enabled {
                try service.unregister()
            }
        }
    }

    /// 진단용 상태 문자열.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled (로그인 시 자동 실행 켜짐)"
        case .notRegistered: return "notRegistered (꺼짐)"
        case .requiresApproval: return "requiresApproval (시스템 설정 > 로그인 항목에서 승인 필요)"
        case .notFound: return "notFound (번들을 찾을 수 없음)"
        @unknown default: return "unknown"
        }
    }
}
