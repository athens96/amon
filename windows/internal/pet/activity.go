// Package pet converts local AI session records into the small, local-only
// presentation model used by the desktop pet.
package pet

import (
	"sort"
	"strings"
	"time"

	"github.com/athens96/amon/windows/internal/session"
)

// SourceActiveInterval is the fallback activity window for sources that do not
// expose turn lifecycle events. Explicit lifecycle state always takes priority.
const SourceActiveInterval = 90 * time.Second

// Status is the activity state understood by the pet animation and bubble.
type Status string

const (
	StatusIdle       Status = "idle"
	StatusRunning    Status = "running"
	StatusNeedsInput Status = "needsInput"
	StatusReady      Status = "ready"
	StatusBlocked    Status = "blocked"
)

// Presentation is one session reduced to the text and counters shown by the
// pet. It deliberately contains no transcript or full prompt/response content.
type Presentation struct {
	Status          Status
	Title           string
	Detail          string
	Output          string
	Provider        string
	SessionID       string
	SessionIdentity string
	InputTokens     int64
	OutputTokens    int64
	TotalTokens     int64
	UpdatedAt       time.Time
	ActiveCount     int
}

// RecordState augments the persisted session.Record with transient live state.
// Status is useful when a collector already resolved the lifecycle. Lifecycle
// accepts raw provider strings such as "turn_started" adapters may translate to
// "active" or "awaiting_approval". ModifiedAt is used only when neither is set.
//
// UpdatedAt is the event timestamp displayed and used for completed-result
// ordering. Title and Detail are optional lifecycle-specific display overrides.
type RecordState struct {
	Status     Status
	Lifecycle  string
	ModifiedAt time.Time
	UpdatedAt  time.Time
	Title      string
	Detail     string
}

// LiveRecord combines a persisted summary with optional transient state. A
// zero RecordState is valid and resolves to idle.
type LiveRecord struct {
	Record session.Record
	State  RecordState
}

// NewLiveRecord is a small convenience for callers that resolve state while
// scanning source files.
func NewLiveRecord(record session.Record, state RecordState) LiveRecord {
	return LiveRecord{Record: record, State: state}
}

// Idle returns the presentation used when there is nothing to show.
func Idle() Presentation {
	return Presentation{
		Status: StatusIdle,
		Title:  "A-mon",
	}
}

// PresentationFor selects the first presentation, or the idle pet when no
// session qualifies.
func PresentationFor(records []LiveRecord, now time.Time) Presentation {
	presentations := Presentations(records, now)
	if len(presentations) == 0 {
		return Idle()
	}
	return presentations[0]
}

// Presentations applies the Codex Pet selection policy:
//
//   - needs-input and blocked states are a single, highest-priority alert;
//   - otherwise only running sessions form the stable 1/N carousel;
//   - otherwise the latest session with output is shown once as ready;
//   - no qualifying record produces an empty slice.
func Presentations(records []LiveRecord, now time.Time) []Presentation {
	if len(records) == 0 {
		return nil
	}

	candidates := make([]candidate, 0, len(records))
	for _, live := range records {
		rec := live.Record
		state := live.State
		candidates = append(candidates, candidate{
			live:   live,
			status: resolveStatus(state, now),
			title: firstNonEmpty(
				normalizedLine(state.Title, 80),
				normalizedLine(rec.ProjectLabel, 80),
				providerTitle(rec.Provider),
			),
			detail: firstNonEmpty(
				normalizedLine(state.Detail, 120),
				normalizedLine(rec.CurrentTask, 120),
			),
			updatedAt: resolveUpdatedAt(live),
		})
	}

	attention := filterCandidates(candidates, func(c candidate) bool {
		return c.status == StatusNeedsInput || c.status == StatusBlocked
	})
	sort.SliceStable(attention, func(i, j int) bool {
		return higherPriority(attention[i], attention[j])
	})
	if len(attention) > 0 {
		return []Presentation{makePresentation(attention[0], 1)}
	}

	running := filterCandidates(candidates, func(c candidate) bool {
		return c.status == StatusRunning
	})
	sort.SliceStable(running, func(i, j int) bool {
		return higherPriority(running[i], running[j])
	})
	if len(running) > 0 {
		out := make([]Presentation, 0, len(running))
		for _, selected := range running {
			out = append(out, makePresentation(selected, len(running)))
		}
		return out
	}

	completed := filterCandidates(candidates, func(c candidate) bool {
		return normalizedLine(c.live.Record.LastResult, 160) != ""
	})
	if len(completed) == 0 {
		return nil
	}
	sort.SliceStable(completed, func(i, j int) bool {
		if !completed[i].updatedAt.Equal(completed[j].updatedAt) {
			return completed[i].updatedAt.After(completed[j].updatedAt)
		}
		return identity(completed[i].live.Record) < identity(completed[j].live.Record)
	})
	completed[0].status = StatusReady
	return []Presentation{makePresentation(completed[0], 0)}
}

// StatusFromString conservatively maps provider lifecycle strings. Unknown
// values remain idle instead of making the pet appear to be working forever.
func StatusFromString(raw string) Status {
	normalized := strings.ToLower(strings.TrimSpace(raw))
	normalized = strings.NewReplacer("-", "_", " ", "_").Replace(normalized)

	switch normalized {
	case "needsinput", "needs_input", "input_required", "awaiting_input", "waiting_for_input",
		"awaiting_approval", "requires_approval", "requires_action":
		return StatusNeedsInput
	case "blocked", "error", "failed", "failure":
		return StatusBlocked
	case "ready", "complete", "completed", "done", "success", "succeeded":
		return StatusReady
	case "active", "running", "working", "in_progress", "busy":
		return StatusRunning
	case "idle", "inactive", "paused", "waiting":
		return StatusIdle
	default:
		return StatusIdle
	}
}

// CarouselIndex finds a selected session and defaults to the first item.
func CarouselIndex(selectedIdentity string, presentations []Presentation) int {
	if selectedIdentity == "" {
		return 0
	}
	for i, presentation := range presentations {
		if presentation.SessionIdentity == selectedIdentity {
			return i
		}
	}
	return 0
}

// MovedIdentity moves by offset with wraparound. It returns an empty identity
// for an empty carousel.
func MovedIdentity(
	selectedIdentity string,
	offset int,
	presentations []Presentation,
) string {
	count := len(presentations)
	if count == 0 {
		return ""
	}
	current := CarouselIndex(selectedIdentity, presentations)
	next := (current + offset%count + count) % count
	return presentations[next].SessionIdentity
}

// PreservedIdentity keeps a selected session across refreshes. If it vanished,
// the previous numeric position is clamped into the refreshed carousel.
func PreservedIdentity(
	selectedIdentity string,
	previousIndex int,
	presentations []Presentation,
) string {
	if len(presentations) == 0 {
		return ""
	}
	if selectedIdentity != "" {
		for _, presentation := range presentations {
			if presentation.SessionIdentity == selectedIdentity {
				return selectedIdentity
			}
		}
	}
	if previousIndex < 0 {
		previousIndex = 0
	}
	if previousIndex >= len(presentations) {
		previousIndex = len(presentations) - 1
	}
	return presentations[previousIndex].SessionIdentity
}

type candidate struct {
	live      LiveRecord
	status    Status
	title     string
	detail    string
	updatedAt time.Time
}

func resolveStatus(state RecordState, now time.Time) Status {
	if state.Status != "" {
		switch state.Status {
		case StatusIdle, StatusRunning, StatusNeedsInput, StatusReady, StatusBlocked:
			return state.Status
		}
		return StatusFromString(string(state.Status))
	}
	if strings.TrimSpace(state.Lifecycle) != "" {
		return StatusFromString(state.Lifecycle)
	}
	if state.ModifiedAt.IsZero() {
		return StatusIdle
	}
	if now.Sub(state.ModifiedAt) <= SourceActiveInterval {
		return StatusRunning
	}
	return StatusIdle
}

func resolveUpdatedAt(live LiveRecord) time.Time {
	if !live.State.UpdatedAt.IsZero() {
		return live.State.UpdatedAt
	}
	if !live.State.ModifiedAt.IsZero() {
		return live.State.ModifiedAt
	}
	return live.Record.EndedAt
}

func makePresentation(selected candidate, activeCount int) Presentation {
	rec := selected.live.Record
	return Presentation{
		Status:          selected.status,
		Title:           selected.title,
		Detail:          selected.detail,
		Output:          normalizedLine(rec.LastResult, 160),
		Provider:        rec.Provider,
		SessionID:       rec.SessionID,
		SessionIdentity: identity(rec),
		InputTokens:     rec.InputTokens,
		OutputTokens:    rec.OutputTokens,
		TotalTokens:     rec.TotalTokens,
		UpdatedAt:       selected.updatedAt,
		ActiveCount:     activeCount,
	}
}

func higherPriority(left, right candidate) bool {
	if statusPriority(left.status) != statusPriority(right.status) {
		return statusPriority(left.status) > statusPriority(right.status)
	}
	if !left.live.Record.StartedAt.Equal(right.live.Record.StartedAt) {
		return left.live.Record.StartedAt.After(right.live.Record.StartedAt)
	}
	return identity(left.live.Record) < identity(right.live.Record)
}

func statusPriority(status Status) int {
	switch status {
	case StatusNeedsInput:
		return 4
	case StatusBlocked:
		return 3
	case StatusReady:
		return 2
	case StatusRunning:
		return 1
	default:
		return 0
	}
}

func filterCandidates(in []candidate, keep func(candidate) bool) []candidate {
	out := make([]candidate, 0, len(in))
	for _, item := range in {
		if keep(item) {
			out = append(out, item)
		}
	}
	return out
}

func identity(record session.Record) string {
	return record.Provider + ":" + record.SessionID
}

func normalizedLine(value string, limit int) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return ""
	}
	if index := strings.IndexAny(trimmed, "\r\n"); index >= 0 {
		trimmed = strings.TrimSpace(trimmed[:index])
	}
	if trimmed == "" {
		return ""
	}
	runes := []rune(trimmed)
	if len(runes) > limit {
		return string(runes[:limit])
	}
	return trimmed
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func providerTitle(provider string) string {
	normalized := strings.TrimSpace(provider)
	if normalized == "" {
		return "A-mon"
	}
	runes := []rune(normalized)
	return strings.ToUpper(string(runes[0])) + string(runes[1:])
}
