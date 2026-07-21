package session

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// 세션 기록 서버 보고 (맥 SessionHistoryReporter 이식).
// 계약: POST {user_key, sessions:[Record…]} → /api/v1/ai-live/history.

const historyPath = "/api/v1/ai-live/history"

// HistoryEndpoint — 베이스 URL → 보고 엔드포인트. 이미 전체 경로면 그대로.
func HistoryEndpoint(serverURL string) string {
	s := strings.TrimRight(strings.TrimSpace(serverURL), "/")
	if s == "" {
		return ""
	}
	if !strings.Contains(s, "/ai-live/history") {
		s += historyPath
	}
	return s
}

// StripLocal — 보고 페이로드용 사본. source_path 는 이 기기의 로그 파일 경로라
// 서버로 보내지 않는다(omitempty 라 비우면 키 자체가 빠진다).
func StripLocal(records []Record) []Record {
	out := make([]Record, len(records))
	for i, rec := range records {
		rec.SourcePath = ""
		out[i] = rec
	}
	return out
}

// Send — 세션 기록 배치 전송. 실패 시 사용자에게 보여줄 한국어 메시지의 error.
func Send(serverURL, userKey string, records []Record) error {
	if len(records) == 0 {
		return nil
	}
	endpoint := HistoryEndpoint(serverURL)
	if endpoint == "" {
		return fmt.Errorf("서버 URL이 올바르지 않습니다")
	}
	key := strings.TrimSpace(userKey)
	if key == "" {
		return fmt.Errorf("유저 키가 비어 있습니다")
	}

	payload, err := json.Marshal(map[string]any{
		"user_key": key,
		"sessions": StripLocal(records),
	})
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Post(endpoint, "application/json", bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("서버에 연결할 수 없습니다: %w", err)
	}
	defer resp.Body.Close()

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	case resp.StatusCode == 401:
		return fmt.Errorf("유효하지 않은 유저 키입니다")
	default:
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 200))
		return fmt.Errorf("서버 오류 %d: %s", resp.StatusCode, string(body))
	}
}
