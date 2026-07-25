package session

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
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
	Timestamp time.Time  // zero 면 없음
	Usage     *TurnUsage // user 턴 전용 — 턴 단위 실측이 없는 프로바이더는 nil
}

// TurnUsage — 이 요청이 유발한 **턴 사용량**(이 요청부터 다음 요청 전까지의 API
// 실측 합, 맥과 동일 규칙). Input 은 입력 텍스트가 아니라 시스템 프롬프트·이전
// 대화를 포함한 요청 컨텍스트 전체다.
type TurnUsage struct {
	Input, Output, CacheRead, CacheWrite, Reasoning, Total int64
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
//
// 토큰은 요청→다음 요청 사이의 assistant usage 를 (message.id, requestId)
// last-wins 로 dedup 해 요청 턴에 귀속한다 — 스캐너와 같은 규칙이라 일간 집계와
// 같은 정확도다. 본문 없는 응답(툴 호출만)과 같은 파일의 sidechain 라인도 이
// 요청이 유발한 소비라 포함한다. 단, 별도 파일로 남는 서브에이전트 소비는 여기
// 안 잡혀 배지 합 < 세션 합계일 수 있다.
func claudeTurns(f *os.File) []Turn {
	var turns []Turn
	openAssistantID := ""
	// 요청 페어 귀속 상태 — pairIndex 는 지금까지 나온 typed 요청 수(1-based).
	// 첫 요청 전(재개 세션 선행분 등)은 0 번에 쌓이고 배지로는 쓰지 않는다.
	pairIndex := 0
	usageByKey := map[string]TurnUsage{}
	pairByKey := map[string]int{}
	anonymous := 0

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	for sc.Scan() {
		var line claudeLine
		if json.Unmarshal(sc.Bytes(), &line) != nil {
			continue
		}
		ts, _ := parseISO(line.Timestamp)

		switch line.Type {
		case "user":
			if line.IsSidechain || line.PromptSource != "typed" || line.Message == nil {
				break
			}
			text := strings.TrimSpace(promptText(line.Message.Content))
			if text == "" {
				break
			}
			openAssistantID = "" // 새 요청이 오면 직전 응답 턴은 닫는다
			pairIndex++
			turns = append(turns, Turn{Role: "user", Text: text, Timestamp: ts})

		case "assistant":
			if line.Message == nil {
				break
			}
			// usage 수집은 본문·sidechain 여부와 무관 — 스트리밍 재등장은
			// 증가만 하므로 last-wins 로 덮고, 귀속 페어도 함께 갱신한다.
			if u := line.Message.Usage; u != nil {
				var key string
				if line.Message.ID != "" {
					key = line.Message.ID + "|" + line.RequestID
				} else {
					anonymous++
					key = "__anon__" + strconv.Itoa(anonymous)
				}
				usageByKey[key] = TurnUsage{
					Input: u.Input, Output: u.Output,
					CacheRead: u.CacheRead, CacheWrite: u.CacheWrite,
					Total: u.Input + u.Output + u.CacheRead + u.CacheWrite,
				}
				pairByKey[key] = pairIndex
			}
			if line.IsSidechain {
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

	pairUsage := map[int]TurnUsage{}
	for key, u := range usageByKey {
		pair := pairByKey[key]
		if pair == 0 {
			continue
		}
		sum := pairUsage[pair]
		sum.Input += u.Input
		sum.Output += u.Output
		sum.CacheRead += u.CacheRead
		sum.CacheWrite += u.CacheWrite
		sum.Reasoning += u.Reasoning
		sum.Total += u.Total
		pairUsage[pair] = sum
	}
	return attachUsage(pairUsage, turns)
}

// codexTurns — 같은 요청이 event_msg(user_message)와 response_item(role=user)
// 양쪽에 기록되므로 직전 요청과 같은 본문이면 건너뛴다.
//
// 토큰은 token_count 이벤트의 **누적**(total_token_usage) 스냅샷을 요청 경계에서
// 델타로 끊어 요청 턴에 귀속한다. 턴 단건(last_token_usage) 합산은 중단/재시도
// 턴에서 누적과 어긋나는 실측 사례가 있어(스캐너의 보정 주석 참조) 권위값인
// 누적을 쓴다 — 맥 SessionTranscriptLoader 와 동일 규칙.
func codexTurns(f *os.File) []Turn {
	var turns []Turn
	pairUsage := map[int]TurnUsage{}
	pairIndex := 0
	var lastCumulative, pairStart TurnUsage

	closePair := func() {
		if pairIndex == 0 {
			return
		}
		pairUsage[pairIndex] = deltaUsage(lastCumulative, pairStart)
	}

	appendUser := func(raw string, ts time.Time) {
		text := strings.TrimSpace(raw)
		if text == "" || !codexIsRealUserMessage(text) {
			return
		}
		if len(turns) > 0 && turns[len(turns)-1].Role == "user" && turns[len(turns)-1].Text == text {
			return
		}
		closePair()
		pairIndex++
		pairStart = lastCumulative
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
			switch line.Payload.Type {
			case "user_message":
				appendUser(line.Payload.Message, ts)
			case "token_count":
				// info:null 하트비트는 스냅샷이 아니다 — 건너뛴다.
				if line.Payload.Info == nil || line.Payload.Info.Total == nil {
					break
				}
				tu := line.Payload.Info.Total
				total := tu.Total
				if total <= 0 {
					total = tu.Input + tu.Output
				}
				lastCumulative = TurnUsage{
					Input:     max64(0, tu.Input-tu.Cached), // input_tokens 는 캐시 히트 포함
					Output:    tu.Output,
					CacheRead: tu.Cached,
					Reasoning: tu.Reasoning,
					Total:     total,
				}
			}
		case "response_item":
			if text := codexUserMessage(line); text != "" {
				appendUser(text, ts)
			} else if text := strings.TrimSpace(codexAssistantText(line)); text != "" {
				turns = append(turns, Turn{Role: "assistant", Text: text, Timestamp: ts})
			}
		}
	}
	closePair()
	return attachUsage(pairUsage, turns)
}

// attachUsage — k 번째(1-based) 요청 턴에 pairUsage[k] 를 붙인다. 소비가 0 인
// 페어는 배지를 만들지 않는다(진행 중 세션에서 아직 응답 전인 마지막 요청 등).
func attachUsage(pairUsage map[int]TurnUsage, turns []Turn) []Turn {
	if len(pairUsage) == 0 {
		return turns
	}
	ordinal := 0
	for i := range turns {
		if turns[i].Role != "user" {
			continue
		}
		ordinal++
		if u, ok := pairUsage[ordinal]; ok && u.Total > 0 {
			usage := u
			turns[i].Usage = &usage
		}
	}
	return turns
}

// deltaUsage — 누적 스냅샷 차. 파일 손상 등으로 역행하면 0 으로 클램프한다.
func deltaUsage(now, base TurnUsage) TurnUsage {
	return TurnUsage{
		Input:      max64(0, now.Input-base.Input),
		Output:     max64(0, now.Output-base.Output),
		CacheRead:  max64(0, now.CacheRead-base.CacheRead),
		CacheWrite: max64(0, now.CacheWrite-base.CacheWrite),
		Reasoning:  max64(0, now.Reasoning-base.Reasoning),
		Total:      max64(0, now.Total-base.Total),
	}
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
