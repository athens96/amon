// Package config — %APPDATA%\A-mon\config.json 에 설정을 영속한다.
// (macOS 개발 머신에서는 ~/Library/Application Support/A-mon/config.json)
package config

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"

	"github.com/athens96/amon/windows/internal/scan"
)

// Config — 서버 보고 설정 + 도구별 로그 경로 오버라이드.
type Config struct {
	ServerURL string     `json:"server_url"` // 예: https://monitor.example.com
	UserKey   string     `json:"user_key"`   // 웹 내정보 설정에서 발급
	Paths     scan.Paths `json:"paths"`      // 빈 항목은 OS 기본 경로
	// AutoUpdate — 새 버전 발견 시 자동 설치. 생략(nil)이면 켬.
	AutoUpdate *bool `json:"auto_update,omitempty"`
	// DeviceID — 설치 단위 안정 ID. 서버가 한 유저의 여러 기기를 구분하는 키로,
	// 호스트명과 달리 네트워크에 따라 변하지 않는다. Load 가 비어 있으면 생성한다.
	DeviceID string `json:"device_id,omitempty"`
	// Pet — 로컬 세션을 데스크톱 펫으로 표시하는 Windows 전용 UI 설정.
	// 작업 문구·응답·펫 위치는 로컬 config에만 저장되고 서버 보고에 포함되지 않는다.
	Pet PetConfig `json:"pet,omitempty"`
	// 대시보드 업로드는 meta+usage_daily 집계만 전송한다.
}

// PetConfig는 nil 포인터로 "구버전 config에 키가 없음"과 명시적인 false를 구분한다.
// 구버전 사용자는 펫 표시/작업 말풍선은 켜지고, 로컬 작업 감지는 동의 전까지 꺼진다.
type PetConfig struct {
	Enabled              *bool  `json:"enabled,omitempty"`
	LocalActivityEnabled *bool  `json:"local_activity_enabled,omitempty"`
	ShowsCurrentTask     *bool  `json:"shows_current_task,omitempty"`
	SpritePath           string `json:"sprite_path,omitempty"`
	SpriteVersion        int    `json:"sprite_version,omitempty"`
	PositionX            *int   `json:"position_x,omitempty"`
	PositionY            *int   `json:"position_y,omitempty"`
}

func (p PetConfig) EnabledValue() bool {
	return p.Enabled == nil || *p.Enabled
}

func (p PetConfig) LocalActivityEnabledValue() bool {
	return p.LocalActivityEnabled != nil && *p.LocalActivityEnabled
}

func (p PetConfig) ShowsCurrentTaskValue() bool {
	return p.ShowsCurrentTask == nil || *p.ShowsCurrentTask
}

func (p PetConfig) SpriteVersionValue() int {
	if p.SpriteVersion == 2 {
		return 2
	}
	return 1
}

func Bool(value bool) *bool { return &value }
func Int(value int) *int    { return &value }

// AutoUpdateEnabled — auto_update 필드가 없으면 기본 켬.
func (c Config) AutoUpdateEnabled() bool {
	return c.AutoUpdate == nil || *c.AutoUpdate
}

// Dir — 설정 디렉토리 (없으면 생성).
func Dir() (string, error) {
	var base string
	if runtime.GOOS == "windows" {
		base = os.Getenv("APPDATA")
	}
	if base == "" {
		var err error
		base, err = os.UserConfigDir()
		if err != nil {
			return "", err
		}
	}
	dir := filepath.Join(base, "A-mon")
	return dir, os.MkdirAll(dir, 0o755)
}

// Path — 설정 파일 전체 경로.
func Path() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.json"), nil
}

// Load — 설정을 읽는다. 파일이 없으면 기본값을 생성해 저장 후 반환한다
// (사용자가 '설정 파일 열기'로 바로 편집할 수 있게).
// device_id 가 비어 있으면 생성해 영속한다(설치 단위 1회).
func Load() (Config, error) {
	var cfg Config
	path, err := Path()
	if err != nil {
		return cfg, err
	}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		cfg.Paths = scan.DefaultPaths()
		cfg.DeviceID = newDeviceID()
		return cfg, Save(cfg)
	}
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, err
	}
	if cfg.DeviceID == "" {
		cfg.DeviceID = newDeviceID()
		if err := Save(cfg); err != nil {
			return cfg, err
		}
	}
	return cfg, nil
}

// newDeviceID — crypto/rand 기반 UUIDv4 형태 문자열 (외부 의존성 없음).
func newDeviceID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// 난수 실패 시에도 빈 값은 피한다 — 호스트명 폴백(서버 폴백과 동일 의미).
		host, _ := os.Hostname()
		return host
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// Save — 설정 저장 (들여쓰기 JSON — 손편집 친화).
func Save(cfg Config) error {
	path, err := Path()
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// ReportConfigured — 서버 URL·유저 키가 모두 채워져 보고 가능한 상태인지.
func (c Config) ReportConfigured() bool {
	return c.ServerURL != "" && c.UserKey != ""
}
