package session

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// 세션 상세 — 원본 로그를 **열 때 그 자리에서** 읽어 요청·응답 전문을 복원한다
// (맥 SessionTranscriptLoader 이식).
//
// 미리 읽어 두지 않는 이유: 트랜스크립트는 세션당 수 MB, 기록은 최대 500건이라
// 전부 들고 있으면 메모리·CPU 낭비다. 목록은 스캐너 요약만 쓰고, 본문은 연
// 세션 1건에 대해서만 읽는다. 결과는 저장하지도, 서버로 보내지도 않는다.

// Turn — 대화 한 턴(요청 또는 응답)의 전체 본문.
type Turn struct {
	Role      string // "user" | "assistant"
	Text      string
	Timestamp time.Time // zero 면 없음
}

var (
	// ErrSourceNotFound — 원본 로그가 지워졌거나 다른 기기에서 만든 세션.
	ErrSourceNotFound = errors.New("원본 로그를 찾을 수 없습니다")
	ErrUnreadable     = errors.New("원본 로그를 읽지 못했습니다")
	// ErrEmpty — 파일은 읽었지만 사람이 읽을 요청·응답이 없다(툴 호출만 있는 세션 등).
	ErrEmpty = errors.New("표시할 대화 내용이 없습니다")
)

// LoadTranscript — 기록의 원본 로그를 읽어 전체 대화를 만든다.
// 파싱 규칙(사람 프롬프트 판별·어시스턴트 텍스트 추출)은 스캐너와 같은 헬퍼를
// 재사용한다 — 두 벌로 갈라지면 목록과 상세가 다른 말을 하게 된다.
func LoadTranscript(rec Record, claudeRoot, codexRoot string) ([]Turn, error) {
	path := ResolveSource(rec, claudeRoot, codexRoot)
	if path == "" {
		return nil, ErrSourceNotFound
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, ErrUnreadable
	}
	defer f.Close()

	var turns []Turn
	if rec.Provider == "codex" {
		turns = codexTurns(f)
	} else {
		turns = claudeTurns(f)
	}
	if len(turns) == 0 {
		return nil, ErrEmpty
	}
	return turns, nil
}

// ResolveSource — SourcePath 가 있으면 그대로 쓰고, 없거나(구버전 기록) 파일이
// 옮겨졌으면 세션 id 로 로그 루트에서 찾는다. 못 찾으면 "".
func ResolveSource(rec Record, claudeRoot, codexRoot string) string {
	if rec.SourcePath != "" {
		if _, err := os.Stat(rec.SourcePath); err == nil {
			return rec.SourcePath
		}
	}
	if rec.Provider == "codex" {
		return locateCodex(rec.SessionID, codexRoot)
	}
	return locateClaude(rec.SessionID, claudeRoot)
}

// locateClaude — <root>/<project>/<sessionId>.jsonl. 파일명이 곧 세션 id.
func locateClaude(sessionID, root string) string {
	if root == "" || sessionID == "" {
		return ""
	}
	projects, err := os.ReadDir(root)
	if err != nil {
		return ""
	}
	for _, project := range projects {
		candidate := filepath.Join(root, project.Name(), sessionID+".jsonl")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return ""
}

// locateCodex — <root>/**/rollout-<timestamp>-<sessionId>.jsonl. 파일명에 id 가 박힌다.
func locateCodex(sessionID, root string) string {
	if root == "" || sessionID == "" {
		return ""
	}
	var found string
	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || found != "" {
			return nil
		}
		base := filepath.Base(path)
		if strings.HasSuffix(base, ".jsonl") && strings.HasPrefix(base, "rollout-") &&
			strings.HasSuffix(strings.TrimSuffix(base, ".jsonl"), sessionID) {
			found = path
		}
		return nil
	})
	return found
}

// claudeTurns — 사람이 친 요청과 어시스턴트 응답만 시간순으로. 서브에이전트
// (sidechain)와 툴 호출/결과는 대화가 아니라 실행 과정이라 제외한다.
//
// 한 응답(message.id)이 콘텐츠 블록마다 여러 줄로 쪼개져 기록되므로 같은 id 의
// 텍스트는 하나의 턴으로 잇되, 같은 본문이 반복된 라인은 버린다(그대로 이으면 중복).
func claudeTurns(f *os.File) []Turn {
	var turns []Turn
	openAssistantID := ""

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	for sc.Scan() {
		var line claudeLine
		if json.Unmarshal(sc.Bytes(), &line) != nil || line.IsSidechain {
			continue
		}
		ts, _ := parseISO(line.Timestamp)

		switch line.Type {
		case "user":
			if line.PromptSource != "typed" || line.Message == nil {
				break
			}
			text := strings.TrimSpace(promptText(line.Message.Content))
			if text == "" {
				break
			}
			openAssistantID = "" // 새 요청이 오면 직전 응답 턴은 닫는다
			turns = append(turns, Turn{Role: "user", Text: text, Timestamp: ts})

		case "assistant":
			if line.Message == nil {
				break
			}
			text := strings.TrimSpace(assistantText(line.Message.Content))
			if text == "" {
				break
			}
			id := line.Message.ID
			if id != "" && id == openAssistantID && len(turns) > 0 &&
				turns[len(turns)-1].Role == "assistant" {
				last := &turns[len(turns)-1]
				if strings.Contains(last.Text, text) {
					break // 같은 응답의 반복 기록
				}
				last.Text += "\n\n" + text
			} else {
				openAssistantID = id
				turns = append(turns, Turn{Role: "assistant", Text: text, Timestamp: ts})
			}
		}
	}
	return turns
}

// codexTurns — 같은 요청이 event_msg(user_message)와 response_item(role=user)
// 양쪽에 기록되므로 직전 요청과 같은 본문이면 건너뛴다.
func codexTurns(f *os.File) []Turn {
	var turns []Turn
	appendUser := func(raw string, ts time.Time) {
		text := strings.TrimSpace(raw)
		if text == "" || !codexIsRealUserMessage(text) {
			return
		}
		if len(turns) > 0 && turns[len(turns)-1].Role == "user" && turns[len(turns)-1].Text == text {
			return
		}
		turns = append(turns, Turn{Role: "user", Text: text, Timestamp: ts})
	}

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	for sc.Scan() {
		var line codexLine
		if json.Unmarshal(sc.Bytes(), &line) != nil {
			continue
		}
		ts, _ := parseISO(line.Timestamp)

		switch line.Type {
		case "event_msg":
			if line.Payload.Type == "user_message" {
				appendUser(line.Payload.Message, ts)
			}
		case "response_item":
			if text := codexUserMessage(line); text != "" {
				appendUser(text, ts)
			} else if text := strings.TrimSpace(codexAssistantText(line)); text != "" {
				turns = append(turns, Turn{Role: "assistant", Text: text, Timestamp: ts})
			}
		}
	}
	return turns
}
