import CoreGraphics

/// amon 기하 토큰 단일 저장소 (Palette=색, Typography=글꼴 과 같은 패턴).
///
/// 모서리 반경과 간격 상수는 이 파일에만 정의한다. 뷰에서 즉석 숫자를 쓰면
/// 카드마다 반경이 10·12·14 로 갈라지던 이전 상태로 되돌아간다.
enum Metrics {

    // MARK: - 모서리 반경

    enum Radius {
        /// 카드 — 히어로·프로바이더 카드·로컬 카드 공통. (이전엔 10 과 14 로 갈렸다.)
        static let card: CGFloat = 12
        /// 카드 안쪽 블록 — 세션 행·토큰 스트립·미터 행·탭.
        static let inset: CGFloat = 8
        /// 소형 컨트롤 — 모드 토글, 화면 전환 아이콘.
        static let control: CGFloat = 6
    }

    // MARK: - 간격

    enum Space {
        /// 카드 안쪽 여백.
        static let card: CGFloat = 12
        /// 섹션과 섹션 사이.
        static let section: CGFloat = 16
        /// 카드 안 요소 사이.
        static let row: CGFloat = 8
        /// 미터 블록 사이 — 제목·막대·상태를 한 덩어리로 읽히게 하려고 일반 간격보다 넓다.
        static let meter: CGFloat = 14
    }

    // MARK: - 고정 치수

    /// 프로바이더 아이콘 탭 한 변 (선택 시 가로로만 늘어난다).
    static let providerTab: CGFloat = 36
    /// 토큰 표의 라벨 열 폭.
    static let labelColumn: CGFloat = 40
    /// 미터 진행 막대 높이.
    static let barHeight: CGFloat = 6
}
