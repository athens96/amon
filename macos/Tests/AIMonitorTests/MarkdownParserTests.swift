import XCTest

@testable import AIMonitor

/// 경량 마크다운 뷰어의 블록 파서 — 코드블록/제목/리스트/인용/구분선/문단 분해 검증.
final class MarkdownParserTests: XCTestCase {

    func testHeadingLevels() {
        XCTAssertEqual(
            MarkdownParser.parse("# 제목\n## 소제목"),
            [.heading(level: 1, content: "제목"), .heading(level: 2, content: "소제목")]
        )
        // # 뒤 공백 없으면 제목이 아니다(문단).
        XCTAssertEqual(MarkdownParser.parse("#태그"), [.paragraph("#태그")])
    }

    func testFencedCodeBlockPreservedVerbatim() {
        let md = "설명\n```swift\nlet x = 1\n#notheading\n```\n끝"
        XCTAssertEqual(
            MarkdownParser.parse(md),
            [
                .paragraph("설명"),
                .codeBlock("let x = 1\n#notheading"),
                .paragraph("끝"),
            ]
        )
    }

    func testUnorderedAndOrderedLists() {
        let md = "- 하나\n- 둘\n1. 첫째\n2. 둘째"
        XCTAssertEqual(
            MarkdownParser.parse(md),
            [
                .listItem(marker: "•", content: "하나", indent: 0),
                .listItem(marker: "•", content: "둘", indent: 0),
                .listItem(marker: "1.", content: "첫째", indent: 0),
                .listItem(marker: "2.", content: "둘째", indent: 0),
            ]
        )
    }

    func testNestedListIndent() {
        let md = "- 상위\n  - 하위"
        XCTAssertEqual(
            MarkdownParser.parse(md),
            [
                .listItem(marker: "•", content: "상위", indent: 0),
                .listItem(marker: "•", content: "하위", indent: 1),
            ]
        )
    }

    func testQuoteAndRule() {
        XCTAssertEqual(
            MarkdownParser.parse("> 인용문\n\n---"),
            [.quote("인용문"), .rule]
        )
    }

    func testParagraphJoinsSoftLines() {
        // 빈 줄 없이 이어진 줄은 한 문단(줄바꿈 보존은 인라인 렌더가 담당).
        XCTAssertEqual(
            MarkdownParser.parse("첫 줄\n둘째 줄\n\n다음 문단"),
            [.paragraph("첫 줄\n둘째 줄"), .paragraph("다음 문단")]
        )
    }

    func testPipeTableParsed() {
        let md = """
        | 이름 | 값 |
        |:-----|----:|
        | a | 1 |
        | b | 2 |
        """
        XCTAssertEqual(
            MarkdownParser.parse(md),
            [
                .table(
                    headers: ["이름", "값"],
                    alignments: [.leading, .trailing],
                    rows: [["a", "1"], ["b", "2"]]
                )
            ]
        )
    }

    func testTableWithoutOuterPipesAndRagged() {
        // 바깥 파이프 없고, 셀 수가 헤더보다 적은 행은 패딩된다.
        let md = "h1 | h2 | h3\n---|---|---\nx | y"
        XCTAssertEqual(
            MarkdownParser.parse(md),
            [
                .table(
                    headers: ["h1", "h2", "h3"],
                    alignments: [.leading, .leading, .leading],
                    rows: [["x", "y", ""]]
                )
            ]
        )
    }

    func testHorizontalRuleNotMistakenForTableSeparator() {
        // 단일 열 --- 는 테이블이 아니라 구분선.
        XCTAssertEqual(MarkdownParser.parse("---"), [.rule])
    }

    func testEscapedPipeInCell() {
        let md = "| a | b |\n|---|---|\n| x \\| y | z |"
        XCTAssertEqual(
            MarkdownParser.parse(md),
            [
                .table(
                    headers: ["a", "b"],
                    alignments: [.leading, .leading],
                    rows: [["x | y", "z"]]
                )
            ]
        )
    }

    func testTaskListCheckboxes() {
        XCTAssertEqual(
            MarkdownParser.parse("- [ ] 안됨\n- [x] 됨"),
            [
                .listItem(marker: "☐", content: "안됨", indent: 0),
                .listItem(marker: "☑", content: "됨", indent: 0),
            ]
        )
    }

    func testInlineAttributedFallsBackAndStylesCode() {
        // 코드 스팬이 monospaced 로 후처리되는지(폰트가 실제로 세팅됨).
        let attributed = MarkdownInline.attributed("보통 `code` 끝", baseSize: 12)
        let hasCodeFont = attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true && run.font != nil
        }
        XCTAssertTrue(hasCodeFont)
        // 원문 텍스트는 보존된다(마크다운 문법 제거 후에도 code 단어 존재).
        XCTAssertTrue(String(attributed.characters).contains("code"))
    }
}
