import AppKit
import XCTest

@testable import AIMonitor

/// Palette.swift — 색상 토큰 단일 저장소 계약 테스트.
///
/// 검증 대상:
///  1. amon 브랜드 액센트 #c9308a 가 라이트 모드에서 정확히 보존되는가
///  2. NSColor dynamicProvider 가 라이트/다크를 실제로 갈라내는가 (다크 전용 잠금 아님)
///  3. hex 문자열 토큰이 전부 파싱 가능한 6자리 형식인가
///  4. 액센트가 프로바이더 색과 충돌하지 않는가 (색상환 거리)
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

    /// 색상환 각도(0~360). hue 충돌 검증용.
    private func hueDegrees(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return -1 }
        return c.hueComponent * 360
    }

    /// 상대 휘도 (WCAG). 흰 글씨 대비 계산용.
    private func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    // MARK: - 1. 브랜드 액센트 보존

    func testLightAccentIsExactlyAmonBrandRose() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        // amon Rose Magenta #c9308a — 프로바이더 색이 비어 있는 275°–360° 구간.
        XCTAssertEqual(rgb255(Palette.accentBase(for: aqua)), [0xc9, 0x30, 0x8a])
    }

    /// 액센트는 흰 글씨를 얹는 채움(모드 토글 선택 세그먼트)으로 쓰인다.
    /// WCAG AA 본문 기준 4.5:1 을 지켜야 한다.
    func testLightAccentKeepsWhiteTextLegible() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let accent = luminance(Palette.accentBase(for: aqua))
        let ratio = (1.0 + 0.05) / (accent + 0.05)
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "흰 글씨 대비가 4.5:1 미만이다: \(ratio)")
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

        let lightColor = Palette.accentBase(for: aqua)
        let darkColor = Palette.accentBase(for: darkAqua)

        // 다크 값은 어두운 서피스 위 가독성을 위해 더 밝아야 한다.
        XCTAssertGreaterThan(
            luminance(darkColor), luminance(lightColor),
            "다크 액센트는 라이트보다 밝아야 한다"
        )

        // 명도만 보정하고 색상(hue)은 유지한다 — 채널 동치가 아니라 각도로 본다.
        // (이전 테스트는 violet 전용으로 R==G, B==0xff 를 박아 두어 색상 변경을 막았다.)
        XCTAssertEqual(
            hueDegrees(darkColor), hueDegrees(lightColor), accuracy: 4,
            "라이트/다크가 같은 색상이어야 한다 — 명도만 보정한다"
        )
    }

    // MARK: - 4. 액센트 ↔ 프로바이더 색 충돌

    /// 액센트는 "선택됨" 한 가지만 뜻하므로 어떤 프로바이더 정체성 색과도
    /// 헷갈리면 안 된다. 이전 #6161ff(240°)는 OpenRouter #6467f2(239°)와 1도 차이였다.
    func testAccentDoesNotCollideWithAnyProviderHue() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let accentHue = hueDegrees(Palette.accentBase(for: aqua))

        for (id, hex) in Palette.providerHexByID {
            let providerColor = try XCTUnwrap(Palette.nsColor(fromHex: hex))
            // 무채색(Grok #111111)은 색상 각도가 의미 없으므로 건너뛴다.
            guard let c = providerColor.usingColorSpace(.sRGB), c.saturationComponent > 0.15 else {
                continue
            }
            let distance = min(
                abs(accentHue - hueDegrees(providerColor)),
                360 - abs(accentHue - hueDegrees(providerColor))
            )
            XCTAssertGreaterThan(
                distance, 25,
                "액센트가 \(id)(\(hex)) 와 색상 \(Int(distance))° 차이 — 구분되지 않는다"
            )
        }
    }

    /// Claude Code 도구 틴트는 Claude 프로바이더 색과 같아야 한다.
    /// 이전엔 액센트를 재사용해 같은 제품이 두 색으로 나왔다.
    func testClaudeCodeToolTintMatchesClaudeProviderColor() throws {
        let expected = try XCTUnwrap(Palette.nsColor(fromHex: Palette.hexClaude))
        let actual = try XCTUnwrap(NSColor(Palette.tintClaudeCode).usingColorSpace(.sRGB))
        XCTAssertEqual(rgb255(actual), rgb255(expected))
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
