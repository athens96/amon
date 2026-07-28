import AppKit
import XCTest

@testable import AIMonitor

/// Palette.swift — 색상 토큰 단일 저장소 계약 테스트.
///
/// 검증 대상:
///  1. amon 브랜드 액센트 #6161ff 가 라이트 모드에서 정확히 보존되는가
///  2. NSColor dynamicProvider 가 라이트/다크를 실제로 갈라내는가 (다크 전용 잠금 아님)
///  3. hex 문자열 토큰이 전부 파싱 가능한 6자리 형식인가
final class PaletteTests: XCTestCase {

    /// sRGB 정수 성분(0~255)으로 환산 — 부동소수 비교 대신 hex 동치를 본다.
    private func rgb255(_ color: NSColor) -> [Int] {
        guard let c = color.usingColorSpace(.sRGB) else {
            XCTFail("sRGB 변환 실패: \(color)")
            return []
        }
        return [c.redComponent, c.greenComponent, c.blueComponent]
            .map { Int(($0 * 255).rounded()) }
    }

    // MARK: - 1. 브랜드 액센트 보존

    func testLightAccentIsExactlyAmonBrandViolet() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        // docs/DESIGN.html: Interactive Violet #6161ff
        XCTAssertEqual(rgb255(Palette.accentBase(for: aqua)), [0x61, 0x61, 0xff])
    }

    func testAccentHexStringMatchesLightAccentColor() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let fromHex = try XCTUnwrap(Palette.nsColor(fromHex: Palette.accentHex))
        // hex 문자열 토큰과 컬러 토큰이 같은 브랜드 색을 가리켜야 한다.
        XCTAssertEqual(rgb255(fromHex), rgb255(Palette.accentBase(for: aqua)))
    }

    // MARK: - 2. dynamicProvider 라이트/다크 적응

    func testDarkAccentDiffersFromLightAccent() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))

        let light = rgb255(Palette.accentBase(for: aqua))
        let dark = rgb255(Palette.accentBase(for: darkAqua))

        // 다크 전용 잠금 금지 — 양쪽이 서로 다른 "의도된" 값이어야 한다.
        XCTAssertNotEqual(light, dark, "다크 모드가 라이트 값을 그대로 쓰면 적응이 아니다")
    }

    func testDarkAccentIsLifterVariantOfSameHue() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))

        let light = rgb255(Palette.accentBase(for: aqua))
        let dark = rgb255(Palette.accentBase(for: darkAqua))

        // 다크 값은 어두운 서피스 위 가독성을 위해 더 밝아야 한다.
        XCTAssertGreaterThan(dark[0], light[0], "다크 액센트 R 은 더 밝아야 한다")
        XCTAssertGreaterThan(dark[1], light[1], "다크 액센트 G 은 더 밝아야 한다")
        // 같은 violet 계열 유지: R==G 이고 B 는 최대치로 고정.
        XCTAssertEqual(dark[0], dark[1], "violet hue 유지 — R 과 G 가 같아야 한다")
        XCTAssertEqual(light[2], 0xff)
        XCTAssertEqual(dark[2], 0xff)
    }

    func testDynamicAccentResolvesPerAppearance() throws {
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        // dynamicProvider 로 만든 NSColor 는 이름을 가진 동적 색이어야 한다.
        XCTAssertEqual(Palette.accentNS.colorNameComponent, "AmonAccent")

        var resolved: [Int] = []
        darkAqua.performAsCurrentDrawingAppearance {
            resolved = self.rgb255(Palette.accentNS)
        }
        XCTAssertEqual(resolved, rgb255(Palette.accentBase(for: darkAqua)))
    }

    // MARK: - 3. hex 토큰 형식

    func testAllHexTokensParse() {
        let tokens: [String: String] = [
            "accent": Palette.accentHex,
            "claude": Palette.hexClaude,
            "codex": Palette.hexCodex,
            "cursor": Palette.hexCursor,
            "copilot": Palette.hexCopilot,
            "openRouter": Palette.hexOpenRouter,
            "devin": Palette.hexDevin,
            "zai": Palette.hexZAI,
            "antigravity": Palette.hexAntigravity,
            "grok": Palette.hexGrok,
            "statusAmber": Palette.hexStatusAmber,
            "statusRed": Palette.hexStatusRed,
            "statusGreen": Palette.hexStatusGreen,
            "statusNeutral": Palette.hexStatusNeutral,
        ]
        for (name, hex) in tokens {
            XCTAssertTrue(hex.hasPrefix("#"), "\(name) 토큰은 # 로 시작해야 한다: \(hex)")
            XCTAssertEqual(hex.count, 7, "\(name) 토큰은 #RRGGBB 7자여야 한다: \(hex)")
            XCTAssertNotNil(Palette.nsColor(fromHex: hex), "\(name) 토큰 파싱 실패: \(hex)")
        }
    }

    func testNSColorFromHexParsesKnownValue() throws {
        let c = try XCTUnwrap(Palette.nsColor(fromHex: "#22c55e"))
        XCTAssertEqual(rgb255(c), [0x22, 0xc5, 0x5e])
    }

    func testNSColorFromHexRejectsMalformedInput() {
        XCTAssertNil(Palette.nsColor(fromHex: "#12345"))
        XCTAssertNil(Palette.nsColor(fromHex: "zzzzzz"))
        XCTAssertNil(Palette.nsColor(fromHex: ""))
    }

    // MARK: - 4. 아이콘 마스크

    func testIconMaskClampsAlphaToOne() {
        XCTAssertEqual(Palette.iconMaskNS(alpha: 2.0).alphaComponent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(Palette.iconMaskNS(alpha: 0.5).alphaComponent, 0.5, accuracy: 0.0001)
    }
}
