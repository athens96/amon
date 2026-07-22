import Foundation

/// 작업 결과 상태 (UI 표시용).
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
