package scan

import (
	"os"
	"path/filepath"
	"runtime"
	"time"
)

// Paths — 도구별 로그 위치. 비어 있으면 DefaultPaths() 값이 쓰인다.
type Paths struct {
	Claude   string `json:"claude"`
	Codex    string `json:"codex"`
	OpenCode string `json:"opencode"`
	Cursor   string `json:"cursor"`
	Gemini   string `json:"gemini"`
	Qwen     string `json:"qwen"`
	Copilot  string `json:"copilot"`
}

// DefaultPaths — OS 별 기본 로그 경로 (2026-07 공식 문서 기준 검증):
//
//   - Claude Code: %USERPROFILE%\.claude\projects — CLAUDE_CONFIG_DIR 오버라이드 지원
//   - Codex CLI:   %USERPROFILE%\.codex\sessions — CODEX_HOME 오버라이드 지원
//   - OpenCode:    Windows 데스크톱 앱은 %LOCALAPPDATA%\opencode\data\opencode.db,
//     그 외 배포는 %APPDATA%\opencode 또는 xdg 스타일 ~\.local\share\opencode —
//     실데이터가 있는 후보를 자동 선택. OPENCODE_DB(파일)/OPENCODE_DATA_DIR 우선
//   - Cursor:      %APPDATA%\Cursor\User\globalStorage\state.vscdb
//
// macOS 기본값도 제공해 개발 머신에서 스캐너 패리티 검증(cmd/scan)이 가능하다.
func DefaultPaths() Paths {
	home, _ := os.UserHomeDir()
	p := Paths{
		Claude: filepath.Join(home, ".claude", "projects"),
		Codex:  filepath.Join(home, ".codex", "sessions"),
	}
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		p.Claude = filepath.Join(dir, "projects")
	}
	if dir := os.Getenv("CODEX_HOME"); dir != "" {
		p.Codex = filepath.Join(dir, "sessions")
	}
	p.OpenCode = defaultOpenCodeDir(home)
	if runtime.GOOS == "windows" {
		p.Cursor = filepath.Join(os.Getenv("APPDATA"), "Cursor", "User", "globalStorage", "state.vscdb")
	} else {
		p.Cursor = filepath.Join(home, "Library", "Application Support",
			"Cursor", "User", "globalStorage", "state.vscdb")
	}

	// 신규 3종 — Claude/Codex 와 같은 홈 기반 경로. env 오버라이드는 서브디렉토리를 붙인다.
	//   Gemini CLI:  %USERPROFILE%\.gemini\tmp\<hash>\chats\session-*.json|jsonl  (GEMINI_DIR → $dir\tmp)
	//   Qwen Code:   %USERPROFILE%\.qwen\projects\**\*.jsonl                       (QWEN_DIR   → $dir\projects)
	//   Copilot CLI: %USERPROFILE%\.copilot\session-state\...                      (COPILOT_DIR→ $dir\session-state)
	p.Gemini = filepath.Join(home, ".gemini", "tmp")
	if dir := os.Getenv("GEMINI_DIR"); dir != "" {
		p.Gemini = filepath.Join(dir, "tmp")
	}
	p.Qwen = filepath.Join(home, ".qwen", "projects")
	if dir := os.Getenv("QWEN_DIR"); dir != "" {
		p.Qwen = filepath.Join(dir, "projects")
	}
	p.Copilot = filepath.Join(home, ".copilot", "session-state")
	if dir := os.Getenv("COPILOT_DIR"); dir != "" {
		p.Copilot = filepath.Join(dir, "session-state")
	}
	return p
}

// defaultOpenCodeDir — OpenCode 데이터 위치 후보를 순서대로 검사해, 실데이터
// (opencode.db 또는 storage/message)가 있는 첫 후보를 고른다. 없으면 첫 후보.
func defaultOpenCodeDir(home string) string {
	if db := os.Getenv("OPENCODE_DB"); db != "" {
		return db // .db 파일 직접 지정 — 스캐너가 그대로 연다
	}
	if dir := os.Getenv("OPENCODE_DATA_DIR"); dir != "" {
		return dir
	}
	var candidates []string
	if runtime.GOOS == "windows" {
		candidates = []string{
			filepath.Join(os.Getenv("LOCALAPPDATA"), "opencode", "data"),                // 데스크톱 앱
			filepath.Join(os.Getenv("LOCALAPPDATA"), "ai.opencode.desktop", "opencode"), // 데스크톱 앱 (번들ID 변형)
			filepath.Join(os.Getenv("APPDATA"), "opencode"),                             // 로밍 배포
			filepath.Join(home, ".local", "share", "opencode"),                          // xdg 스타일 CLI
		}
	} else {
		candidates = []string{
			filepath.Join(home, ".local", "share", "opencode"),                                       // CLI (xdg)
			filepath.Join(home, "Library", "Application Support", "ai.opencode.desktop", "opencode"), // macOS 데스크톱 앱
			filepath.Join(home, "Library", "Application Support", "opencode"),
		}
	}
	for _, c := range candidates {
		if hasOpenCodeData(c) {
			return c
		}
	}
	return candidates[0]
}

// hasOpenCodeData — 이 디렉토리에 실사용 데이터가 있는지.
func hasOpenCodeData(dir string) bool {
	if _, err := os.Stat(filepath.Join(dir, "opencode.db")); err == nil {
		return true
	}
	return dirExists(filepath.Join(dir, "storage", "message"))
}

// WithDefaults — 빈 항목을 기본 경로로 채운 사본.
func (p Paths) WithDefaults() Paths {
	def := DefaultPaths()
	if p.Claude == "" {
		p.Claude = def.Claude
	}
	if p.Codex == "" {
		p.Codex = def.Codex
	}
	if p.OpenCode == "" {
		p.OpenCode = def.OpenCode
	}
	if p.Cursor == "" {
		p.Cursor = def.Cursor
	}
	if p.Gemini == "" {
		p.Gemini = def.Gemini
	}
	if p.Qwen == "" {
		p.Qwen = def.Qwen
	}
	if p.Copilot == "" {
		p.Copilot = def.Copilot
	}
	return p
}

// ScanAll — 모든 도구를 순서대로 스캔해 요약 배열을 돌려준다. 순서는 맥과 동일.
func ScanAll(paths Paths) []ToolSummary {
	paths = paths.WithDefaults()
	start := WindowStart(time.Now())
	return []ToolSummary{
		ScanClaude(paths.Claude, start),
		ScanCodex(paths.Codex, start),
		ScanOpenCode(paths.OpenCode, start),
		ScanCursor(paths.Cursor, start),
		ScanGemini(paths.Gemini, start),
		ScanQwen(paths.Qwen, start),
		ScanCopilot(paths.Copilot, start),
	}
}
