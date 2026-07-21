import Foundation

/// 서버 보고 상태 (UI 표시용).
enum ReportOutcome: Equatable {
    case idle
    case sending
    case success(Date)
    case failure(String)
}

enum ReportError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}
