// Package session — 종료된 AI CLI 세션 기록 (macOS SessionHistory* 이식).
//
// Claude Code 트랜스크립트·Codex rollout 을 스캔해 세션 요약(SessionRecord)을
// 만들고 JSONL 저장소에 적재한다. 목록에는 요청/응답의 **첫 줄 요약**만 담고,
// 전문은 상세를 열 때 원본 로그를 그 자리에서 읽는다(transcript.go).
//
// macOS 와 다른 점: Windows 에는 훅이 없어 pending(정확한 종료 시각)·라이브
// 세션 신호가 없다. 종료 판정은 "최근 15분 내 수정 없음"(activeGrace) 뿐이고,
// 종료 시각은 로그의 마지막 타임스탬프다 — 맥의 로그 백필 경로와 동일 규칙.
package session

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// MaxPrompts — 한 세션에 보관하는 요청 줄 수 상한. 맥 SessionRecord.maxPrompts.
const MaxPrompts = 50

// MaxRecords — 로컬에 남기는 최대 세션 수. 맥 SessionHistoryStore.maxRecords.
const MaxRecords = 500

// ActiveGrace — 이 시간 안에 수정된 로그는 아직 진행 중일 수 있어 기록하지 않는다.
const ActiveGrace = 15 * time.Minute

// SessionLimit — 프로바이더당 스캔할 최근 파일 수 상한. 맥과 동일.
const SessionLimit = 200

// Record — 종료된 세션 1건. JSON 은 snake_case — 백엔드 AISessionHistoryReport
// 계약 및 맥 SessionRecord CodingKeys 와 1:1.
type Record struct {
	Provider     string           `json:"provider"` // "claude" | "codex"
	SessionID    string           `json:"session_id"`
	ProjectLabel string           `json:"project_label"`
	GitBranch    string           `json:"git_branch,omitempty"`
	StartedAt    time.Time        `json:"started_at"`
	EndedAt      time.Time        `json:"ended_at"`
	Prompts      []string         `json:"prompts"` // 요청 첫 줄, 시간순 최대 MaxPrompts
	PromptCount  int              `json:"prompt_count"`
	CurrentTask  string           `json:"current_task,omitempty"` // = prompts 마지막
	LastResult   string           `json:"last_result,omitempty"`  // 마지막 응답 첫 줄
	InputTokens  int64            `json:"input_tokens"`
	OutputTokens int64            `json:"output_tokens"`
	CacheTokens  int64            `json:"cache_tokens"`
	TotalTokens  int64            `json:"total_tokens"`
	Models       map[string]int64 `json:"models"`
	AgentCount   int              `json:"agent_count"`
	// SourcePath — 이 세션의 원본 로그 경로. **로컬 전용** — 상세(전문)를 열 때만
	// 쓰고 서버 보고에서는 제거한다(report.go). omitempty 라 비우면 키가 빠진다.
	SourcePath string `json:"source_path,omitempty"`
}

// ID — 같은 세션이 두 번 적재되지 않도록 하는 키(프로바이더 간 id 충돌 방지).
func (r Record) ID() string { return r.Provider + ":" + r.SessionID }

// Store — 세션 기록 JSONL 저장소(한 줄 = 한 세션). 추가 전용이고, 읽을 때
// ID 기준 최신 것만 남긴다. MaxRecords 를 넘으면 오래된 순으로 잘라 다시 쓴다.
type Store struct {
	Path string
	mu   sync.Mutex
}

// Load — 저장된 기록을 종료 시각 내림차순으로. 파일이 없으면 빈 슬라이스.
func (st *Store) Load() []Record {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.loadLocked()
}

func (st *Store) loadLocked() []Record {
	f, err := os.Open(st.Path)
	if err != nil {
		return nil
	}
	defer f.Close()

	byID := map[string]Record{}
	var order []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for sc.Scan() {
		var rec Record
		if json.Unmarshal(sc.Bytes(), &rec) != nil || rec.SessionID == "" {
			continue
		}
		if _, ok := byID[rec.ID()]; !ok {
			order = append(order, rec.ID())
		}
		byID[rec.ID()] = rec // 같은 세션 재적재는 마지막 것이 이긴다
	}
	out := make([]Record, 0, len(order))
	for _, id := range order {
		out = append(out, byID[id])
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].EndedAt.After(out[j].EndedAt) })
	return out
}

// Upsert — 새 기록 적재(이미 있는 ID 는 갱신). 바뀐 게 없으면 파일을 건드리지
// 않는다. 반환은 병합된 전체(종료 시각 내림차순, 상한 적용).
func (st *Store) Upsert(records []Record) []Record {
	st.mu.Lock()
	defer st.mu.Unlock()

	byID := map[string]Record{}
	for _, rec := range st.loadLocked() {
		byID[rec.ID()] = rec
	}
	changed := false
	for _, rec := range records {
		if prev, ok := byID[rec.ID()]; !ok || !equalRecord(prev, rec) {
			byID[rec.ID()] = rec
			changed = true
		}
	}
	merged := make([]Record, 0, len(byID))
	for _, rec := range byID {
		merged = append(merged, rec)
	}
	sort.Slice(merged, func(i, j int) bool { return merged[i].EndedAt.After(merged[j].EndedAt) })
	if len(merged) > MaxRecords {
		merged = merged[:MaxRecords]
		changed = true
	}
	if changed {
		st.writeLocked(merged)
	}
	return merged
}

func (st *Store) writeLocked(records []Record) {
	_ = os.MkdirAll(filepath.Dir(st.Path), 0o755)
	f, err := os.CreateTemp(filepath.Dir(st.Path), ".sessions-*")
	if err != nil {
		return
	}
	w := bufio.NewWriter(f)
	// 파일은 오래된 것부터(append 로그처럼) 두어 사람이 읽기 쉽게 한다.
	for i := len(records) - 1; i >= 0; i-- {
		line, err := json.Marshal(records[i])
		if err != nil {
			continue
		}
		w.Write(line)
		w.WriteByte('\n')
	}
	w.Flush()
	f.Close()
	_ = os.Rename(f.Name(), st.Path)
}

// equalRecord — 변경 감지용 비교. 시간은 표시 정밀도가 아니라 절대 시각으로.
func equalRecord(a, b Record) bool {
	aj, _ := json.Marshal(a)
	bj, _ := json.Marshal(b)
	return string(aj) == string(bj)
}

// firstLine — 앞뒤 공백 제거 후 첫 줄을 limit 자로 자른다. 빈 줄이면 "".
func firstLine(s string, limit int) string {
	trimmed := strings.TrimSpace(s)
	if trimmed == "" {
		return ""
	}
	if i := strings.IndexByte(trimmed, '\n'); i >= 0 {
		trimmed = strings.TrimSpace(trimmed[:i])
	}
	runes := []rune(trimmed)
	if len(runes) > limit {
		return string(runes[:limit])
	}
	return trimmed
}
