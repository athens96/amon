// Package provider reads local CLI credentials and fetches live usage windows.
package provider

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	cacheDuration = 2 * time.Minute
	requestLimit  = 10 * time.Second
)

type Metric struct {
	Label       string
	UsedPercent float64
	ResetsAt    time.Time
}

func (m Metric) RemainingPercent() float64 {
	return math.Max(0, math.Min(100, 100-m.UsedPercent))
}

type Snapshot struct {
	ID, Name, Plan, Status string
	Metrics                []Metric
	RefreshedAt            time.Time
}

type Manager struct {
	client *http.Client
	now    func() time.Time

	mu        sync.RWMutex
	cache     []Snapshot
	fetchedAt time.Time
}

func NewManager() *Manager {
	return &Manager{client: &http.Client{Timeout: requestLimit}, now: time.Now}
}

func (m *Manager) Invalidate() {
	m.mu.Lock()
	m.fetchedAt = time.Time{}
	m.mu.Unlock()
}

func (m *Manager) Cached() []Snapshot {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return append([]Snapshot(nil), m.cache...)
}

func (m *Manager) Fetch(ctx context.Context) []Snapshot {
	m.mu.RLock()
	if !m.fetchedAt.IsZero() && m.now().Sub(m.fetchedAt) < cacheDuration {
		cached := append([]Snapshot(nil), m.cache...)
		m.mu.RUnlock()
		return cached
	}
	m.mu.RUnlock()

	type result struct {
		snapshot Snapshot
		detected bool
	}
	results := make(chan result, 2)
	go func() {
		s, ok := m.fetchClaude(ctx)
		results <- result{s, ok}
	}()
	go func() {
		s, ok := m.fetchCodex(ctx)
		results <- result{s, ok}
	}()

	snapshots := make([]Snapshot, 0, 2)
	for range 2 {
		r := <-results
		if r.detected {
			snapshots = append(snapshots, r.snapshot)
		}
	}
	if len(snapshots) == 2 && snapshots[0].ID == "codex" {
		snapshots[0], snapshots[1] = snapshots[1], snapshots[0]
	}

	m.mu.Lock()
	m.cache = append([]Snapshot(nil), snapshots...)
	m.fetchedAt = m.now()
	m.mu.Unlock()
	return snapshots
}

type codexAuth struct {
	Tokens struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		AccountID    string `json:"account_id"`
	} `json:"tokens"`
}

func (m *Manager) fetchCodex(ctx context.Context) (Snapshot, bool) {
	path, raw, auth, ok := loadCodexAuth()
	if !ok {
		return Snapshot{}, false
	}
	snapshot := Snapshot{ID: "codex", Name: "Codex", RefreshedAt: m.now()}
	accessToken := auth.Tokens.AccessToken
	if expiresAt, ok := jwtExpiresAt(accessToken); ok && expiresAt.Sub(m.now()) <= 5*time.Minute {
		if auth.Tokens.RefreshToken == "" {
			snapshot.Status = "로그인이 만료되었습니다"
			return snapshot, true
		}
		fresh, refresh, err := m.refreshCodex(ctx, auth.Tokens.RefreshToken)
		if err != nil {
			snapshot.Status = "로그인을 갱신하지 못했습니다"
			return snapshot, true
		}
		accessToken = fresh
		if refresh != "" {
			auth.Tokens.RefreshToken = refresh
		}
		auth.Tokens.AccessToken = accessToken
		persistCodexAuth(path, raw, auth)
	}

	body, err := m.getJSON(ctx, "https://chatgpt.com/backend-api/wham/usage", map[string]string{
		"Authorization":      "Bearer " + accessToken,
		"Accept":             "application/json",
		"User-Agent":         "A-mon",
		"ChatGPT-Account-Id": auth.Tokens.AccountID,
	})
	if err != nil {
		snapshot.Status = statusText(err)
		return snapshot, true
	}
	snapshot.Plan = codexPlan(text(body["plan_type"]))
	rateLimit, _ := body["rate_limit"].(map[string]any)
	if metric, ok := codexWindow("세션", object(rateLimit["primary_window"]), m.now()); ok {
		snapshot.Metrics = append(snapshot.Metrics, metric)
	}
	if metric, ok := codexWindow("주간", object(rateLimit["secondary_window"]), m.now()); ok {
		snapshot.Metrics = append(snapshot.Metrics, metric)
	}
	if len(snapshot.Metrics) == 0 {
		snapshot.Status = "사용 한도 데이터가 없습니다"
	}
	return snapshot, true
}

func loadCodexAuth() (string, map[string]any, codexAuth, bool) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", nil, codexAuth{}, false
	}
	paths := []string{filepath.Join(home, ".config", "codex", "auth.json"), filepath.Join(home, ".codex", "auth.json")}
	if custom := strings.TrimSpace(os.Getenv("CODEX_HOME")); custom != "" {
		paths = []string{filepath.Join(custom, "auth.json")}
	}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var auth codexAuth
		var raw map[string]any
		if json.Unmarshal(data, &auth) == nil && json.Unmarshal(data, &raw) == nil && auth.Tokens.AccessToken != "" {
			return path, raw, auth, true
		}
	}
	return "", nil, codexAuth{}, false
}

func (m *Manager) refreshCodex(ctx context.Context, refreshToken string) (string, string, error) {
	form := url.Values{
		"grant_type":    {"refresh_token"},
		"client_id":     {"app_EMoamEEZ73f0CkXaXp7hrann"},
		"refresh_token": {refreshToken},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://auth.openai.com/oauth/token", strings.NewReader(form.Encode()))
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	var response struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	if err := m.doJSON(req, &response); err != nil || response.AccessToken == "" {
		if err == nil {
			err = errors.New("empty access token")
		}
		return "", "", err
	}
	return response.AccessToken, response.RefreshToken, nil
}

func persistCodexAuth(path string, raw map[string]any, auth codexAuth) {
	tokens, _ := raw["tokens"].(map[string]any)
	if tokens == nil {
		tokens = map[string]any{}
		raw["tokens"] = tokens
	}
	tokens["access_token"] = auth.Tokens.AccessToken
	if auth.Tokens.RefreshToken != "" {
		tokens["refresh_token"] = auth.Tokens.RefreshToken
	}
	raw["last_refresh"] = time.Now().UTC().Format(time.RFC3339Nano)
	if data, err := json.MarshalIndent(raw, "", "  "); err == nil {
		_ = os.WriteFile(path, data, 0o600)
	}
}

type claudeCredentials struct {
	OAuth struct {
		AccessToken      string   `json:"accessToken"`
		RefreshToken     string   `json:"refreshToken"`
		ExpiresAt        float64  `json:"expiresAt"`
		SubscriptionType string   `json:"subscriptionType"`
		RateLimitTier    string   `json:"rateLimitTier"`
		Scopes           []string `json:"scopes"`
	} `json:"claudeAiOauth"`
}

func (m *Manager) fetchClaude(ctx context.Context) (Snapshot, bool) {
	path, credentials, ok := loadClaudeCredentials()
	if !ok {
		return Snapshot{}, false
	}
	snapshot := Snapshot{ID: "claude", Name: "Claude", Plan: claudePlan(credentials.OAuth.SubscriptionType, credentials.OAuth.RateLimitTier), RefreshedAt: m.now()}
	accessToken := credentials.OAuth.AccessToken
	if credentials.OAuth.ExpiresAt > 0 && credentials.OAuth.ExpiresAt-float64(m.now().UnixMilli()) <= float64((5*time.Minute)/time.Millisecond) {
		if credentials.OAuth.RefreshToken == "" {
			snapshot.Status = "로그인이 만료되었습니다"
			return snapshot, true
		}
		fresh, refresh, expiresIn, err := m.refreshClaude(ctx, credentials.OAuth.RefreshToken)
		if err != nil {
			snapshot.Status = "로그인을 갱신하지 못했습니다"
			return snapshot, true
		}
		accessToken = fresh
		credentials.OAuth.AccessToken = fresh
		if refresh != "" {
			credentials.OAuth.RefreshToken = refresh
		}
		if expiresIn > 0 {
			credentials.OAuth.ExpiresAt = float64(m.now().Add(time.Duration(expiresIn * float64(time.Second))).UnixMilli())
		}
		if data, err := json.MarshalIndent(credentials, "", "  "); err == nil {
			_ = os.WriteFile(path, data, 0o600)
		}
	}

	body, err := m.getJSON(ctx, "https://api.anthropic.com/api/oauth/usage", map[string]string{
		"Authorization":  "Bearer " + accessToken,
		"Accept":         "application/json",
		"Content-Type":   "application/json",
		"anthropic-beta": "oauth-2025-04-20",
		"User-Agent":     "claude-code/2.1.69",
	})
	if err != nil {
		snapshot.Status = statusText(err)
		return snapshot, true
	}
	if metric, ok := claudeWindow("세션", object(body["five_hour"])); ok {
		snapshot.Metrics = append(snapshot.Metrics, metric)
	}
	if metric, ok := claudeWindow("주간", object(body["seven_day"])); ok {
		snapshot.Metrics = append(snapshot.Metrics, metric)
	}
	if len(snapshot.Metrics) == 0 {
		snapshot.Status = "사용 한도 데이터가 없습니다"
	}
	return snapshot, true
}

func loadClaudeCredentials() (string, claudeCredentials, bool) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", claudeCredentials{}, false
	}
	base := filepath.Join(home, ".claude")
	if custom := strings.TrimSpace(os.Getenv("CLAUDE_CONFIG_DIR")); custom != "" {
		base = custom
	}
	path := filepath.Join(base, ".credentials.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", claudeCredentials{}, false
	}
	var credentials claudeCredentials
	if json.Unmarshal(data, &credentials) != nil || credentials.OAuth.AccessToken == "" {
		return "", claudeCredentials{}, false
	}
	return path, credentials, true
}

func (m *Manager) refreshClaude(ctx context.Context, refreshToken string) (string, string, float64, error) {
	body, _ := json.Marshal(map[string]any{
		"grant_type": "refresh_token", "refresh_token": refreshToken,
		"client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
		"scope":     "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://platform.claude.com/v1/oauth/token", strings.NewReader(string(body)))
	if err != nil {
		return "", "", 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	var response struct {
		AccessToken  string  `json:"access_token"`
		RefreshToken string  `json:"refresh_token"`
		ExpiresIn    float64 `json:"expires_in"`
	}
	if err := m.doJSON(req, &response); err != nil || response.AccessToken == "" {
		if err == nil {
			err = errors.New("empty access token")
		}
		return "", "", 0, err
	}
	return response.AccessToken, response.RefreshToken, response.ExpiresIn, nil
}

type httpStatusError int

func (e httpStatusError) Error() string { return fmt.Sprintf("HTTP %d", int(e)) }

func (m *Manager) getJSON(ctx context.Context, endpoint string, headers map[string]string) (map[string]any, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	for key, value := range headers {
		if value != "" {
			req.Header.Set(key, value)
		}
	}
	var body map[string]any
	if err := m.doJSON(req, &body); err != nil {
		return nil, err
	}
	return body, nil
}

func (m *Manager) doJSON(req *http.Request, target any) error {
	response, err := m.client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, response.Body)
		return httpStatusError(response.StatusCode)
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 2<<20))
	decoder.UseNumber()
	return decoder.Decode(target)
}

func codexWindow(label string, window map[string]any, now time.Time) (Metric, bool) {
	used, ok := number(window["used_percent"])
	if !ok {
		return Metric{}, false
	}
	if seconds, ok := number(window["limit_window_seconds"]); ok {
		label = quotaWindowLabel(label, seconds)
	}
	metric := Metric{Label: label, UsedPercent: clampPercent(used)}
	if resetAt, ok := number(window["reset_at"]); ok {
		metric.ResetsAt = time.Unix(int64(resetAt), 0)
	} else if after, ok := number(window["reset_after_seconds"]); ok {
		metric.ResetsAt = now.Add(time.Duration(after * float64(time.Second)))
	}
	return metric, true
}

func quotaWindowLabel(fallback string, seconds float64) string {
	switch {
	case seconds > 0 && seconds <= 6*60*60:
		return "세션"
	case seconds >= 6*24*60*60 && seconds <= 8*24*60*60:
		return "주간"
	default:
		return fallback
	}
}

func claudeWindow(label string, window map[string]any) (Metric, bool) {
	used, ok := number(window["utilization"])
	if !ok {
		return Metric{}, false
	}
	metric := Metric{Label: label, UsedPercent: clampPercent(used)}
	if raw := text(window["resets_at"]); raw != "" {
		metric.ResetsAt, _ = time.Parse(time.RFC3339Nano, raw)
	}
	return metric, true
}

func number(value any) (float64, bool) {
	switch value := value.(type) {
	case json.Number:
		n, err := value.Float64()
		return n, err == nil
	case float64:
		return value, true
	case int:
		return float64(value), true
	case string:
		n, err := strconv.ParseFloat(value, 64)
		return n, err == nil
	default:
		return 0, false
	}
}

func object(value any) map[string]any {
	object, _ := value.(map[string]any)
	if object == nil {
		return map[string]any{}
	}
	return object
}

func text(value any) string {
	text, _ := value.(string)
	return strings.TrimSpace(text)
}

func clampPercent(value float64) float64 { return math.Max(0, math.Min(100, value)) }

func jwtExpiresAt(token string) (time.Time, bool) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return time.Time{}, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return time.Time{}, false
	}
	var claims map[string]any
	decoder := json.NewDecoder(strings.NewReader(string(payload)))
	decoder.UseNumber()
	if decoder.Decode(&claims) != nil {
		return time.Time{}, false
	}
	expires, ok := number(claims["exp"])
	return time.Unix(int64(expires), 0), ok
}

func codexPlan(raw string) string {
	switch strings.ToLower(raw) {
	case "prolite":
		return "Pro 5x"
	case "pro":
		return "Pro 20x"
	default:
		if raw == "" {
			return ""
		}
		return strings.ToUpper(raw[:1]) + strings.ReplaceAll(raw[1:], "_", " ")
	}
}

func claudePlan(subscription, tier string) string {
	if subscription == "" {
		return ""
	}
	plan := strings.ToUpper(subscription[:1]) + strings.ToLower(subscription[1:])
	for _, field := range strings.FieldsFunc(tier, func(r rune) bool { return r == '_' || r == '-' }) {
		if strings.HasSuffix(field, "x") {
			if _, err := strconv.Atoi(strings.TrimSuffix(field, "x")); err == nil {
				return plan + " " + field
			}
		}
	}
	return plan
}

func statusText(err error) string {
	var status httpStatusError
	if errors.As(err, &status) {
		switch int(status) {
		case http.StatusUnauthorized, http.StatusForbidden:
			return "로그인이 만료되었습니다"
		case http.StatusTooManyRequests:
			return "잠시 후 다시 시도하세요"
		default:
			return fmt.Sprintf("조회 실패 (HTTP %d)", int(status))
		}
	}
	return "네트워크 연결을 확인하세요"
}
