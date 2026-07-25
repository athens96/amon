// Package report — 에이전트 대시보드 업로드 채널. 로컬 usage.db 스냅샷을 multipart 로
// 백엔드(POST /api/v1/ai-agents/report)에 올린다. 파일에는 meta와 usage_daily
// 집계만 있으며 로컬 세션·프롬프트·프로젝트 정보는 포함하지 않는다.
package report

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"strings"
	"time"
)

const dashboardPath = "/api/v1/ai-agents/report"

// DashboardEndpoint — 베이스 URL → 업로드 엔드포인트. 이미 전체 경로면 그대로.
func DashboardEndpoint(serverURL string) string {
	s := strings.TrimRight(strings.TrimSpace(serverURL), "/")
	if s == "" {
		return ""
	}
	if !strings.Contains(s, "/ai-agents/report") {
		s += dashboardPath
	}
	return s
}

// UploadSignature returns a destination-aware digest for automatic upload deduplication.
// Changing the server or user key must resend unchanged usage to the new account.
// Only the digest is persisted; the key is not copied into upload state.
func UploadSignature(contentSignature, serverURL, userKey string) string {
	h := sha256.New()
	_, _ = io.WriteString(h, DashboardEndpoint(serverURL))
	_, _ = h.Write([]byte{0})
	_, _ = io.WriteString(h, strings.TrimSpace(userKey))
	_, _ = h.Write([]byte{0})
	_, _ = io.WriteString(h, contentSignature)
	return hex.EncodeToString(h.Sum(nil))
}

// FileSHA256 — 파일의 SHA-256 hex. 업로드 변경 감지용.
func FileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// SendDashboard — usage.db 스냅샷을 multipart(user_key + db)로 업로드.
// 실패 시 사용자에게 보여줄 한국어 메시지의 error.
func SendDashboard(serverURL, userKey, dbPath string) error {
	endpoint := DashboardEndpoint(serverURL)
	if endpoint == "" {
		return fmt.Errorf("서버 URL이 올바르지 않습니다")
	}
	key := strings.TrimSpace(userKey)
	if key == "" {
		return fmt.Errorf("유저 키가 비어 있습니다")
	}

	f, err := os.Open(dbPath)
	if err != nil {
		return fmt.Errorf("업로드 파일을 열 수 없습니다: %w", err)
	}
	defer f.Close()

	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	if err := w.WriteField("user_key", key); err != nil {
		return err
	}
	part, err := w.CreateFormFile("db", "usage-upload.db") // Content-Type: application/octet-stream
	if err != nil {
		return err
	}
	if _, err := io.Copy(part, f); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}

	req, err := http.NewRequest("POST", endpoint, &body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", w.FormDataContentType())
	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("서버에 연결할 수 없습니다: %w", err)
	}
	defer resp.Body.Close()

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	case resp.StatusCode == 401:
		return fmt.Errorf("유효하지 않은 유저 키입니다")
	case resp.StatusCode == 413:
		return fmt.Errorf("업로드 크기가 서버 한도를 초과했습니다")
	default:
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 200))
		return fmt.Errorf("서버 오류 %d: %s", resp.StatusCode, string(b))
	}
}
