import AppKit
import SwiftUI

/// amon 색상 토큰 단일 저장소 (Typography.swift 패턴).
///
/// 모든 색상 상수는 이 파일에만 정의한다.
/// 다른 파일에서 Color(red:) / NSColor(...) / 하드코딩 hex 리터럴을 쓰지 않는다.
/// 라이트/다크 적응이 필요한 값은 NSColor dynamicProvider 또는 Color(nsColor:)를 사용한다.
enum Palette {

    // MARK: - 브랜드 액센트 (라이트/다크 적응)

    /// 라이트 모드 브랜드 액센트 — docs/DESIGN.html "Interactive Violet #6161ff" 정확값.
    static let accentLightBase = NSColor(
        srgbRed: 0x61 / 255.0, green: 0x61 / 255.0, blue: 0xff / 255.0, alpha: 1
    )

    /// 다크 모드 브랜드 액센트 — 같은 violet 색상(hue)을 흰색 쪽으로 들어올린 #7d7dff.
    /// 어두운 서피스 위에서 #6161ff 는 가라앉아 보이므로 명도만 보정한다.
    /// 라이트 모드 액센트와 같은 hue를 유지한 amon 다크 모드 파생값이다.
    static let accentDarkBase = NSColor(
        srgbRed: 0x7d / 255.0, green: 0x7d / 255.0, blue: 0xff / 255.0, alpha: 1
    )

    /// dynamicProvider 본체 — 외관에 따라 브랜드 액센트를 고른다.
    /// 순수 함수라 테스트에서 외관을 직접 넣어 검증할 수 있다.
    static func accentBase(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? accentDarkBase
            : accentLightBase
    }

    /// 브랜드 액센트 NSColor — 시스템 라이트/다크 전환에 자동 대응한다.
    static let accentNS = NSColor(name: NSColor.Name("AmonAccent")) { appearance in
        accentBase(for: appearance)
    }

    /// amon Interactive Violet — 앱 전역 1차 액센트. 라이트/다크 적응.
    static let accent = Color(nsColor: accentNS)

    /// 동일 색상 hex 문자열 — Provider 액센트 기본값 · 메뉴바 아이콘 fallback
    static let accentHex = "#6161ff"

    // MARK: - 도구별 틴트 (AITool.tint)

    /// Claude Code — Interactive Violet (브랜드 동일 토큰 재사용, 라이트/다크 적응)
    static let tintClaudeCode = accent
    /// Codex CLI — Teal
    static let tintCodex      = Color(red: 0x00 / 255.0, green: 0xa6 / 255.0, blue: 0x8f / 255.0)
    /// OpenCode — Sunset
    static let tintOpenCode   = Color(red: 0xf6 / 255.0, green: 0x7d / 255.0, blue: 0x3c / 255.0)
    /// Cursor — Sky Blue
    static let tintCursor     = Color(red: 0x2e / 255.0, green: 0x7d / 255.0, blue: 0xf6 / 255.0)
    /// Gemini CLI — Google Blue
    static let tintGemini     = Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xf4 / 255.0)
    /// Qwen Code — Purple
    static let tintQwen       = Color(red: 0x83 / 255.0, green: 0x35 / 255.0, blue: 0xd6 / 255.0)
    /// Copilot CLI — Green
    static let tintCopilot    = Color(red: 0x1a / 255.0, green: 0x7f / 255.0, blue: 0x64 / 255.0)

    // MARK: - 아이콘 미리보기 배경 (SettingsView 내장 아이콘 타일)

    /// 설정 화면 아이콘 썸네일 배경 — 흰색 선화가 라이트 모드에서 보이게 어두운 타일 위에 올린다
    static let iconPreviewBackground = Color(red: 0.16, green: 0.16, blue: 0.18)

    // MARK: - 프로바이더 액센트 hex 문자열

    /// Claude — Warm Orange (공식 claude.ai 브랜드)
    static let hexClaude      = "#d97757"
    /// Codex / OpenAI
    static let hexCodex       = "#10a37f"
    /// Cursor
    static let hexCursor      = "#2e7df6"
    /// Copilot / GitHub
    static let hexCopilot     = "#6e40c9"
    /// OpenRouter
    static let hexOpenRouter  = "#6467f2"
    /// Devin
    static let hexDevin       = "#4b3fa7"
    /// Z.AI
    static let hexZAI         = "#3a6df0"
    /// Antigravity
    static let hexAntigravity = "#00857a"
    /// Grok / xAI
    static let hexGrok        = "#111111"

    static let providerHexByID: [String: String] = [
        "claude": hexClaude,
        "codex": hexCodex,
        "openai": hexCodex,
        "cursor": hexCursor,
        "copilot": hexCopilot,
        "openrouter": hexOpenRouter,
        "devin": hexDevin,
        "zai": hexZAI,
        "z.ai": hexZAI,
        "antigravity": hexAntigravity,
        "grok": hexGrok,
    ]

    static func providerTint(forID id: String) -> Color? {
        providerHexByID[id.lowercased()].flatMap { hex in
            nsColor(fromHex: hex).map(Color.init(nsColor:))
        }
    }

    // MARK: - 상태 배지 색 hex (MetricLine badge colorHex)

    /// 대기 / 주의 — Amber
    static let hexStatusAmber   = "#F59E0B"
    /// 오류 — Red
    static let hexStatusRed     = "#EF4444"
    /// 양호 — Green
    static let hexStatusGreen   = "#22c55e"
    /// 중립 / 없음 — Neutral Gray
    static let hexStatusNeutral = "#a3a3a3"

    // MARK: - 시스템 어댑터

    /// NSColor hex 팩토리 — `NSColor(hex:)` 호출을 Palette 안으로 격리한다.
    /// 라이트/다크 무관, 정적 sRGB 색.
    ///
    /// hex 문자열은 관례상 sRGB 이므로 반드시 `srgbRed:` 로 만든다.
    /// (calibrated/genericRGB 로 만들면 #22c55e 가 화면에서 rgb(27,204,113) 로
    ///  어긋나 프로바이더 액센트·상태 배지 색이 전부 틀어진다.)
    static func nsColor(fromHex hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let value = UInt32(h, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    /// 아이콘 마스크 검정 — AppIcons 알파 부스트 합성용
    static func iconMaskNS(alpha: CGFloat) -> NSColor {
        NSColor(deviceRed: 0, green: 0, blue: 0, alpha: min(1.0, alpha))
    }
}
