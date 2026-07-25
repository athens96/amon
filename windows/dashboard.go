package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"

	"github.com/athens96/amon/windows/internal/config"
	"github.com/athens96/amon/windows/internal/report"
	"github.com/athens96/amon/windows/internal/scan"
	"github.com/athens96/amon/windows/internal/session"
	"github.com/athens96/amon/windows/internal/store"
)

// dashSync — 에이전트 대시보드 저장(로컬 usage.db)·업로드 상태.
//
// 스캔 결과는 매 주기 usage.db 에 적재해 로컬 UI 의 데이터 소스로 삼고, 서버
// 연동(server_url+user_key)이 설정돼 있으면 내용이 바뀌었을 때만 서버로 올린다
// (별도 토글 없음 — 서버 연동 설정이 곧 전송 동의).
type dashSync struct {
	store   *store.Store
	dbPath  string
	tmpPath string
	sigFile string
	lastSig string
}

// newDashSync — usage.db 를 열고 마지막 업로드 서명을 복원한다. 열기 실패 시 nil
// (저장 계층 없이도 로컬 스캔·세션 기록은 계속된다).
func newDashSync() *dashSync {
	dir, err := config.Dir()
	if err != nil {
		return nil
	}
	st, err := store.Open(filepath.Join(dir, "usage.db"))
	if err != nil {
		return nil
	}
	d := &dashSync{
		store:   st,
		dbPath:  st.Path(),
		tmpPath: filepath.Join(dir, "usage-upload.db"),
		sigFile: filepath.Join(dir, "cache", "dashboard-upload.json"),
	}
	d.lastSig = loadUploadSig(d.sigFile)
	return d
}

func (d *dashSync) close() {
	if d != nil && d.store != nil {
		_ = d.store.Close()
	}
}

// persist — usage.db 에 스캔 결과를 저장하고, 서버 설정됨 + 내용 변경시
// meta+usage_daily 전용의 새 스냅샷을 서버로 업로드한다.
func (d *dashSync) persist(summaries []scan.ToolSummary, records []session.Record) {
	if d == nil || d.store == nil {
		return
	}
	cfg, _ := config.Load()
	if err := d.store.Save(summaries, records, store.Meta{
		Machine:    hostname(),
		AppVersion: appVersion,
		DeviceID:   cfg.DeviceID,
	}); err != nil {
		return
	}

	if !cfg.ReportConfigured() {
		return
	}
	sig := report.UploadSignature(contentSignature(summaries), cfg.ServerURL, cfg.UserKey)
	if sig == d.lastSig {
		return // 내용 무변화 — 재업로드 생략
	}
	if err := d.store.UploadSnapshot(d.tmpPath); err != nil {
		return
	}
	defer os.Remove(d.tmpPath)
	if err := report.SendDashboard(cfg.ServerURL, cfg.UserKey, d.tmpPath); err != nil {
		return
	}
	d.lastSig = sig
	saveUploadSig(d.sigFile, sig)
}

// contentSignature — 서버 업로드 허용 데이터(일자별 사용량)의 결정적 SHA-256.
// 로컬 세션 기록과 tool_totals 전용 필드는 서명에도 포함하지 않는다.
func contentSignature(summaries []scan.ToolSummary) string {
	h := sha256.New()
	for _, summary := range summaries {
		uploadContent := struct {
			Tool             string
			DailyByModel     map[string]map[string]scan.TokenUsage
			DailyCostByModel map[string]map[string]float64
		}{
			Tool: summary.Tool, DailyByModel: summary.DailyByModel,
			DailyCostByModel: summary.DailyCostByModel,
		}
		if b, err := json.Marshal(uploadContent); err == nil {
			h.Write(b)
		}
	}
	return hex.EncodeToString(h.Sum(nil))
}

// uploadState — 마지막 업로드 서명 사이드카(config.json 을 손편집 친화로 두기 위해 분리).
type uploadState struct {
	Sig string `json:"sig"`
}

func loadUploadSig(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var s uploadState
	if json.Unmarshal(data, &s) != nil {
		return ""
	}
	return s.Sig
}

func saveUploadSig(path, sig string) {
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	if b, err := json.Marshal(uploadState{Sig: sig}); err == nil {
		_ = os.WriteFile(path, b, 0o644)
	}
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "unknown"
	}
	return h
}
