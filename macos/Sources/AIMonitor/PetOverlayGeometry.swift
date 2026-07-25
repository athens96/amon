import CoreGraphics

enum PetBubblePlacement: Equatable {
    case left
    case right
}

struct PetOverlayExpansion: Equatable {
    let frame: CGRect
    let bubblePlacement: PetBubblePlacement
}

/// 펫의 현재 위치를 유지하면서 말풍선을 화면 안쪽으로 펼치는 순수 좌표 계산.
enum PetOverlayGeometry {
    private static let padding: CGFloat = 8
    private static let bubbleWidth: CGFloat = 226
    private static let itemSpacing: CGFloat = 8
    private static let avatarSize = CGSize(width: 126, height: 148)

    static func avatarFrame(
        in size: CGSize,
        bubblePlacement: PetBubblePlacement
    ) -> CGRect {
        let hasBubble = size.width
            >= bubbleWidth + itemSpacing + avatarSize.width + padding * 2
        let contentWidth = hasBubble
            ? bubbleWidth + itemSpacing + avatarSize.width
            : avatarSize.width
        let contentLeading = padding + max(
            0,
            size.width - padding * 2 - contentWidth
        )
        let avatarX = hasBubble && bubblePlacement == .left
            ? contentLeading + bubbleWidth + itemSpacing
            : contentLeading
        return CGRect(
            origin: CGPoint(x: avatarX, y: padding),
            size: avatarSize
        )
    }

    static func carouselControlFrame(
        in size: CGSize,
        bubblePlacement: PetBubblePlacement
    ) -> CGRect {
        let contentWidth = bubbleWidth + itemSpacing + avatarSize.width
        let contentLeading = padding + max(
            0,
            size.width - padding * 2 - contentWidth
        )
        let bubbleX = bubblePlacement == .left
            ? contentLeading
            : contentLeading + avatarSize.width + itemSpacing
        return CGRect(
            x: bubbleX + 136,
            y: size.height - 50,
            width: 94,
            height: 46
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
