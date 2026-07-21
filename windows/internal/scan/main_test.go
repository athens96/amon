package scan

import (
	"os"
	"testing"
)

// TestMain — 스캔 테스트를 이 개발 머신의 실제 Orca 코덱스 세션 홈으로부터 격리한다.
// (codexRoots 의 폴백이 존재하면 임시 디렉토리 테스트에 실데이터가 새어든다.)
// 다중 root 병합을 검증하는 테스트는 codexOrcaSessions 를 명시적으로 설정한다.
func TestMain(m *testing.M) {
	codexOrcaSessions = ""
	os.Exit(m.Run())
}
