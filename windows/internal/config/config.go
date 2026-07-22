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

// Config — 업데이트 서버 설정 + 도구별 로그 경로 오버라이드.
type Config struct {
	ServerURL string     `json:"server_url"` // 예: https://monitor.example.com
	Paths     scan.Paths `json:"paths"`      // 빈 항목은 OS 기본 경로
	// AutoUpdate — 새 버전 발견 시 자동 설치. 생략(nil)이면 켬.
	AutoUpdate *bool `json:"auto_update,omitempty"`
	// DeviceID — 설치 단위 안정 ID. 서버가 한 유저의 여러 기기를 구분하는 키로,
	// 호스트명과 달리 네트워크에 따라 변하지 않는다. Load 가 비어 있으면 생성한다.
	DeviceID string `json:"device_id,omitempty"`
}

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
