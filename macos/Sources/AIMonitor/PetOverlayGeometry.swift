import CoreGraphics

enum PetBubblePlacement: Equatable {
    case left
    case right
}

struct PetOverlayExpansion: Equatable {
    let frame: CGRect
    let bubblePlacement: PetBubblePlacement
}

/// 펫의 현재 위치를 유지하면서 말풍선을 화면 안쪽으로 펼치고 크기를 조절하는
/// 순수 좌표 계산.
///
/// 패널 좌표는 AppKit 기준(원점 좌하단)이다. 펫 아바타는 항상 패널 하단에
/// 붙어 있으므로, 말풍선이 커질 때 패널의 하단(minY)과 아바타 쪽 가장자리를
/// 고정하면 펫이 화면에서 움직이지 않는다.
enum PetOverlayGeometry {
    static let padding: CGFloat = 8
    static let itemSpacing: CGFloat = 8
    static let avatarSize = CGSize(width: 126, height: 148)

    /// 사용자가 드래그로 조절할 수 있는 말풍선 크기 범위.
    static let minimumBubbleSize = CGSize(width: 226, height: 150)
    static let maximumBubbleSize = CGSize(width: 720, height: 560)
    static let defaultBubbleSize = minimumBubbleSize

    /// 리사이즈 그립의 한 변 길이 — 말풍선 바깥쪽 위 모서리에 놓인다.
    static let resizeGripLength: CGFloat = 22
    /// 말풍선 테두리에서 이 두께 안쪽까지는 크기 조절로 잡는다.
    static let resizeEdgeThickness: CGFloat = 8
    /// 이 거리를 넘겨야 펫 이동으로 본다. 넘지 않고 버튼을 떼면 클릭이다.
    static let dragThreshold: CGFloat = 4
    /// 끌고 가는 동안 주행 방향을 다시 판정하는 최소 좌우 이동량.
    static let locomotionStep: CGFloat = 2

    /// 말풍선을 숨겼을 때의 패널 크기(아바타 + 여백).
    static var compactSize: CGSize {
        CGSize(
            width: padding * 2 + avatarSize.width,
            height: padding * 2 + avatarSize.height
        )
    }

    static func clampedBubbleSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minimumBubbleSize.width), maximumBubbleSize.width),
            height: min(max(size.height, minimumBubbleSize.height), maximumBubbleSize.height)
        )
    }

    /// 현재 디스플레이의 가시 영역 안에 펫과 말풍선이 함께 들어가도록 최대 크기를
    /// 한 번 더 제한한다. 최소 크기조차 들어가지 않는 비정상적으로 작은 화면에서는
    /// 기존 최소 크기를 유지한다.
    static func bubbleSize(
        _ size: CGSize,
        fitting visibleFrame: CGRect,
        margin: CGFloat = 8
    ) -> CGSize {
        let clamped = clampedBubbleSize(size)
        let availableWidth =
            visibleFrame.width - margin * 2 - padding * 2 - itemSpacing - avatarSize.width
        let availableHeight = visibleFrame.height - margin * 2 - padding * 2
        return CGSize(
            width: max(minimumBubbleSize.width, min(clamped.width, availableWidth)),
            height: max(minimumBubbleSize.height, min(clamped.height, availableHeight))
        )
    }

    /// 말풍선 크기에 맞는 패널 전체 크기.
    static func panelSize(bubble: CGSize) -> CGSize {
        let bubble = clampedBubbleSize(bubble)
        return CGSize(
            width: padding * 2 + bubble.width + itemSpacing + avatarSize.width,
            height: padding * 2 + max(avatarSize.height, bubble.height)
        )
    }

    /// 패널 크기에서 말풍선이 차지하는 크기를 되돌린다.
    static func bubbleSize(in size: CGSize) -> CGSize {
        CGSize(
            width: size.width - padding * 2 - itemSpacing - avatarSize.width,
            height: size.height - padding * 2
        )
    }

    static func hasBubble(in size: CGSize) -> Bool {
        size.width >= panelSize(bubble: minimumBubbleSize).width
    }

    /// 아바타(펫)가 차지하는 패널 내부 영역 — 클릭 판정에 쓴다.
    /// 말풍선이 왼쪽이면 아바타는 오른쪽 끝, 아니면 왼쪽 끝에 붙는다.
    static func avatarFrame(
        in size: CGSize,
        bubblePlacement: PetBubblePlacement
    ) -> CGRect {
        let avatarX = hasBubble(in: size) && bubblePlacement == .left
            ? size.width - padding - avatarSize.width
            : padding
        return CGRect(
            origin: CGPoint(x: avatarX, y: padding),
            size: avatarSize
        )
    }

    /// 말풍선 카드가 차지하는 패널 내부 영역.
    static func bubbleFrame(
        in size: CGSize,
        bubblePlacement: PetBubblePlacement
    ) -> CGRect {
        let bubble = bubbleSize(in: size)
        let bubbleX = bubblePlacement == .left
            ? padding
            : padding + avatarSize.width + itemSpacing
        return CGRect(
            origin: CGPoint(x: bubbleX, y: padding),
            size: CGSize(width: max(0, bubble.width), height: max(0, bubble.height))
        )
    }

    /// 캐러셀 화살표는 말풍선 헤더 오른쪽 끝에 있다. SwiftUI 버튼으로 이벤트를
    /// 넘겨야 하므로 패널 드래그와 구분할 히트 영역을 계산한다.
    static func carouselControlFrame(
        in size: CGSize,
        bubblePlacement: PetBubblePlacement
    ) -> CGRect {
        let bubble = bubbleFrame(in: size, bubblePlacement: bubblePlacement)
        return CGRect(
            x: bubble.maxX - 90,
            y: bubble.maxY - 40,
            width: 82,
            height: 34
        )
    }

    /// 리사이즈 그립 — 말풍선의 아바타 반대쪽 위 모서리.
    static func resizeGripFrame(
        in size: CGSize,
        bubblePlacement: PetBubblePlacement
    ) -> CGRect {
        let bubble = bubbleFrame(in: size, bubblePlacement: bubblePlacement)
        let gripX = bubblePlacement == .left
            ? bubble.minX
            : bubble.maxX - resizeGripLength
        return CGRect(
            x: gripX,
            y: bubble.maxY - resizeGripLength,
            width: resizeGripLength,
            height: resizeGripLength
        )
    }

    /// 크기 조절을 시작할 수 있는 지점과 조절 축.
    enum ResizeHandle: Equatable {
        /// 바깥쪽 위 모서리 — 가로·세로 동시.
        case corner
        /// 바깥쪽 세로 테두리 — 가로만.
        case horizontal
        /// 위쪽 테두리 — 세로만.
        case vertical
    }

    /// 말풍선 테두리를 눌렀는지 판정한다. 아바타 쪽 안쪽 테두리는 대상이 아니다.
    static func resizeHandle(
        at point: CGPoint,
        in size: CGSize,
        bubblePlacement: PetBubblePlacement
    ) -> ResizeHandle? {
        guard hasBubble(in: size) else { return nil }
        let bubble = bubbleFrame(in: size, bubblePlacement: bubblePlacement)
        guard bubble.insetBy(dx: -2, dy: -2).contains(point) else { return nil }

        if resizeGripFrame(in: size, bubblePlacement: bubblePlacement).contains(point) {
            return .corner
        }
        let nearOuterEdge = bubblePlacement == .left
            ? point.x <= bubble.minX + resizeEdgeThickness
            : point.x >= bubble.maxX - resizeEdgeThickness
        let nearTopEdge = point.y >= bubble.maxY - resizeEdgeThickness
        switch (nearOuterEdge, nearTopEdge) {
        case (true, true): return .corner
        case (true, false): return .horizontal
        case (false, true): return .vertical
        case (false, false): return nil
        }
    }

    /// 테두리를 끈 거리(화면 좌표, 위쪽이 +y)를 새 말풍선 크기로 바꾼다.
    /// 바깥쪽·위쪽으로 끌면 커진다.
    static func resizedBubbleSize(
        from bubble: CGSize,
        translation: CGSize,
        bubblePlacement: PetBubblePlacement,
        handle: ResizeHandle = .corner
    ) -> CGSize {
        let outwardWidth = bubblePlacement == .left
            ? -translation.width
            : translation.width
        let widthDelta = handle == .vertical ? 0 : outwardWidth
        let heightDelta = handle == .horizontal ? 0 : translation.height
        return clampedBubbleSize(
            CGSize(
                width: bubble.width + widthDelta,
                height: bubble.height + heightDelta
            )
        )
    }

    /// 리사이즈 후 패널 프레임 — 펫이 움직이지 않도록 하단과 아바타 쪽 모서리를 고정한다.
    static func resizedPanelFrame(
        from frame: CGRect,
        bubble: CGSize,
        bubblePlacement: PetBubblePlacement,
        visibleFrame: CGRect,
        margin: CGFloat = 8
    ) -> CGRect {
        let size = panelSize(bubble: bubble)
        let originX = bubblePlacement == .left
            ? frame.maxX - size.width
            : frame.minX
        return constrained(
            CGRect(
                origin: CGPoint(x: originX, y: frame.minY),
                size: size
            ),
            to: visibleFrame,
            margin: margin
        )
    }

    static func expanded(
        from compactFrame: CGRect,
        expandedSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 8
    ) -> PetOverlayExpansion {
        let addedWidth = max(0, expandedSize.width - compactFrame.width)
        let leftSpace = compactFrame.minX - (visibleFrame.minX + margin)
        let rightSpace = (visibleFrame.maxX - margin) - compactFrame.maxX
        let placement: PetBubblePlacement =
            leftSpace >= addedWidth || leftSpace >= rightSpace ? .left : .right
        let originX = placement == .left
            ? compactFrame.maxX - expandedSize.width
            : compactFrame.minX
        let proposed = CGRect(
            origin: CGPoint(x: originX, y: compactFrame.minY),
            size: expandedSize
        )
        return PetOverlayExpansion(
            frame: constrained(proposed, to: visibleFrame, margin: margin),
            bubblePlacement: placement
        )
    }

    static func collapsed(
        from expandedFrame: CGRect,
        compactSize: CGSize,
        bubblePlacement: PetBubblePlacement,
        visibleFrame: CGRect,
        margin: CGFloat = 8
    ) -> CGRect {
        let originX = bubblePlacement == .left
            ? expandedFrame.maxX - compactSize.width
            : expandedFrame.minX
        return constrained(
            CGRect(
                origin: CGPoint(x: originX, y: expandedFrame.minY),
                size: compactSize
            ),
            to: visibleFrame,
            margin: margin
        )
    }

    static func constrained(
        _ frame: CGRect,
        to visibleFrame: CGRect,
        margin: CGFloat = 8
    ) -> CGRect {
        let minimumX = visibleFrame.minX + margin
        let minimumY = visibleFrame.minY + margin
        let maximumX = max(minimumX, visibleFrame.maxX - frame.width - margin)
        let maximumY = max(minimumY, visibleFrame.maxY - frame.height - margin)
        return CGRect(
            origin: CGPoint(
                x: min(max(frame.minX, minimumX), maximumX),
                y: min(max(frame.minY, minimumY), maximumY)
            ),
            size: frame.size
        )
    }
}
