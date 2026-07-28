import SwiftUI

/// 세션 상세 대화 본문용 경량 마크다운 뷰어 (외부 의존성 0).
///
/// amon 은 서드파티 마크다운 라이브러리를 쓰지 않으므로, 블록 단위 파싱은 직접
/// 하고 인라인 서식(굵게·기울임·코드·링크)만 Foundation 의
/// `AttributedString(markdown:)` 에 맡긴다. 지원 블록: 제목(#~######), 펜스 코드
/// 블록(``` ), 순서/비순서 리스트, 인용(>), 구분선(---), 문단. 표·중첩 리스트 등은
/// 대화 로그에 드물어 문단으로 흘려보낸다(원문은 그대로 보이므로 정보 손실 없음).
struct MarkdownView: View {
    let text: String
    /// 본문 기본 글자 크기. 제목/코드 크기는 여기서 파생한다.
    var baseSize: CGFloat = 12
    /// 문단·리스트 본문 색(요청=primary, 응답=secondary 로 구분).
    var textColor: Color = .primary

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            inlineText(content)
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let content):
            inlineText(content)
                .font(.system(size: baseSize))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: baseSize, design: .monospaced))
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

        case .listItem(let marker, let content, let indent):
            HStack(alignment: .top, spacing: 6) {
                Text(marker)
                    .font(.system(size: baseSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                inlineText(content)
                    .font(.system(size: baseSize))
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 14)

        case .quote(let content):
            HStack(spacing: 6) {
                Rectangle()
                    .fill(MenuBarContentView.accent.opacity(0.5))
                    .frame(width: 2)
                inlineText(content)
                    .font(.system(size: baseSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .rule:
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(height: 0.5)
                .padding(.vertical, 2)

        case .table(let headers, let alignments, let rows):
            tableView(headers: headers, alignments: alignments, rows: rows)
        }
    }

    /// GFM 테이블 — Grid 로 열 정렬. 넓으면 가로 스크롤한다.
    /// (@ViewBuilder 아님 — 중첩 헬퍼 func 를 두려고 단일 뷰를 명시적으로 반환한다.)
    private func tableView(
        headers: [String], alignments: [MarkdownColumnAlignment], rows: [[String]]
    ) -> some View {
        let columns = headers.count
        func align(_ col: Int) -> Alignment {
            switch col < alignments.count ? alignments[col] : .leading {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
        func hAlign(_ col: Int) -> HorizontalAlignment {
            switch col < alignments.count ? alignments[col] : .leading {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { col in
                        inlineText(col < headers.count ? headers[col] : "")
                            .font(.system(size: baseSize, weight: .semibold))
                            .foregroundStyle(textColor)
                            .frame(maxWidth: .infinity, alignment: align(col))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .gridColumnAlignment(hAlign(col))
                    }
                }
                .background(Color.primary.opacity(0.06))
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, cells in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { col in
                            inlineText(col < cells.count ? cells[col] : "")
                                .font(.system(size: baseSize))
                                .foregroundStyle(textColor)
                                .frame(maxWidth: .infinity, alignment: align(col))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }
                    .background(
                        rowIndex.isMultiple(of: 2)
                            ? Color.clear : Color.primary.opacity(0.03)
                    )
                    if rowIndex < rows.count - 1 { Divider() }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
        }
    }

    /// 인라인 서식을 적용한 Text — 코드 스팬은 monospaced, 링크는 accent.
    private func inlineText(_ content: String) -> Text {
        Text(MarkdownInline.attributed(content, baseSize: baseSize))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 5
        case 2: return baseSize + 3
        case 3: return baseSize + 2
        default: return baseSize + 1
        }
    }
}

// MARK: - 블록 모델

enum MarkdownColumnAlignment: Equatable {
    case leading, center, trailing
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, content: String)
    case paragraph(String)
    case codeBlock(String)
    /// marker = "•"/"1." 등 렌더링용 접두. 체크리스트는 "☐"/"☑". indent = 중첩 깊이.
    case listItem(marker: String, content: String, indent: Int)
    case quote(String)
    case rule
    /// GFM 파이프 테이블. rows 는 헤더 열 수에 맞춰 패딩/절단된다.
    case table(headers: [String], alignments: [MarkdownColumnAlignment], rows: [[String]])
}

// MARK: - 블록 파서

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // 줄바꿈 정규화 후 라인 배열로. 끝의 개행 손실은 무의미.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 펜스 코드 블록 — 여는 ``` 부터 닫는 ``` 까지 원문 그대로.
            if let fence = fenceMarker(trimmed) {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let inner = lines[index].trimmingCharacters(in: .whitespaces)
                    if inner.hasPrefix(fence), fenceMarker(inner) != nil { index += 1; break }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.codeBlock(stripTrailingBlank(code).joined(separator: "\n")))
                continue
            }

            // 빈 줄 = 문단 경계.
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // 구분선.
            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // 제목.
            if let (level, content) = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, content: content))
                index += 1
                continue
            }

            // 인용.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(content))
                index += 1
                continue
            }

            // GFM 파이프 테이블 — `|` 를 포함한 헤더 줄 + 다음 줄이 구분 줄일 때만.
            if trimmed.contains("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let headers = splitTableRow(line)
                let alignments = tableAlignments(lines[index + 1], columns: headers.count)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index]
                    let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                    guard rowTrimmed.contains("|"), !rowTrimmed.isEmpty else { break }
                    var cells = splitTableRow(rowLine)
                    // 헤더 열 수에 맞춰 패딩/절단.
                    if cells.count < headers.count {
                        cells += Array(repeating: "", count: headers.count - cells.count)
                    } else if cells.count > headers.count {
                        cells = Array(cells.prefix(headers.count))
                    }
                    rows.append(cells)
                    index += 1
                }
                blocks.append(.table(headers: headers, alignments: alignments, rows: rows))
                continue
            }

            // 리스트(순서/비순서). 앞 공백 2칸당 한 단계 들여쓰기.
            if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
                index += 1
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    /// ``` 또는 ~~~ 펜스면 그 마커(3자)를 반환.
    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let sets: [Character] = ["-", "*", "_"]
        for marker in sets {
            if trimmed.allSatisfy({ $0 == marker }) { return true }
        }
        return false
    }

    /// 리스트 항목이면 (marker, content, indent) 로 만든다.
    private static func listItem(_ raw: String) -> MarkdownBlock? {
        let leadingSpaces = raw.prefix { $0 == " " }.count
        let indent = min(leadingSpaces / 2, 4)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // 비순서: -, *, + 뒤 공백.
        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            let content = String(trimmed.dropFirst(bullet.count))
            // 체크리스트: [ ] / [x] / [X].
            if content.hasPrefix("[ ] ") {
                return .listItem(marker: "☐", content: String(content.dropFirst(4)), indent: indent)
            }
            if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                return .listItem(marker: "☑", content: String(content.dropFirst(4)), indent: indent)
            }
            return .listItem(marker: "•", content: content, indent: indent)
        }
        // 순서: 숫자 + . 또는 ) + 공백.
        if let match = orderedPrefix(trimmed) {
            return .listItem(marker: match.marker, content: match.content, indent: indent)
        }
        return nil
    }

    private static func orderedPrefix(_ trimmed: String) -> (marker: String, content: String)? {
        var digits = ""
        var rest = Substring(trimmed)
        while let first = rest.first, first.isNumber {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let sep = rest.first, sep == "." || sep == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        return ("\(digits).", String(rest.dropFirst(0)).trimmingCharacters(in: .whitespaces))
    }

    // MARK: 테이블

    /// 구분 줄 판정 — `|` 로 나눈 각 셀이 `:?-+:?`(최소 하이픈 1개, 정렬 콜론 허용).
    /// 열이 하나뿐이면 구분선(---)과 헷갈리므로 2열 이상만 테이블로 본다.
    static func isTableSeparator(_ line: String) -> Bool {
        let cells = splitTableRow(line)
        guard cells.count >= 2 else { return false }
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            var body = Substring(trimmed)
            if body.first == ":" { body = body.dropFirst() }
            if body.last == ":" { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return false }
        }
        return true
    }

    /// 구분 줄에서 열별 정렬(`:---`=leading, `:---:`=center, `---:`=trailing).
    static func tableAlignments(_ line: String, columns: Int) -> [MarkdownColumnAlignment] {
        let cells = splitTableRow(line)
        var out: [MarkdownColumnAlignment] = []
        for i in 0..<columns {
            let trimmed = i < cells.count
                ? cells[i].trimmingCharacters(in: .whitespaces) : ""
            let left = trimmed.hasPrefix(":")
            let right = trimmed.hasSuffix(":")
            if left && right { out.append(.center) } else if right { out.append(.trailing) } else {
                out.append(.leading)
            }
        }
        return out
    }

    /// 한 행을 셀로 분해. 바깥쪽 파이프는 제거하고, `\|` 이스케이프는 리터럴로.
    static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }

        var cells: [String] = []
        var current = ""
        var iterator = trimmed.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let ch = next() {
            if ch == "\\" {
                if let after = next() {
                    if after == "|" { current.append("|") } else {
                        current.append("\\"); current.append(after)
                    }
                } else {
                    current.append("\\")
                }
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// 코드 블록 끝의 빈 줄들을 제거(펜스 앞 개행이 빈 줄로 잡히는 것 정리).
    private static func stripTrailingBlank(_ lines: [String]) -> [String] {
        var out = lines
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            out.removeLast()
        }
        return out
    }
}

// MARK: - 인라인 서식

enum MarkdownInline {
    /// 문단/제목/리스트 본문의 인라인 마크다운을 AttributedString 으로.
    /// 실패하면 원문을 그대로(정보 손실 없음). 코드 스팬은 monospaced 로 후처리한다.
    static func attributed(_ text: String, baseSize: CGFloat) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        let mono = Font.system(size: baseSize, design: .monospaced)
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = mono
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = MenuBarContentView.accent
            }
        }
        return attributed
    }
}
