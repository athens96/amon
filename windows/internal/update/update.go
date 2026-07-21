// Package update — 서버 릴리즈 채널 기반 자동 업데이트 (Windows).
//
// macOS Updater.swift 와 동일 프로토콜:
//
//	GET  {base}/api/v1/app/latest?platform=windows   → {version, filename, sha256, size_bytes}
//	GET  {base}/api/v1/app/download/{version}?platform=windows
//
// 아티팩트는 zip(내부에 A-mon-amd64.exe / A-mon-arm64.exe) 또는 단일 exe.
// zip 이면 실행 중인 아키텍처(runtime.GOARCH)와 이름이 맞는 exe 를 고른다.
//
// Windows 는 실행 중인 exe 를 덮어쓸 수 없으므로: 새 exe 를 옆에 저장한 뒤
// 배치 스크립트가 (프로세스 종료를 기다리며) move 를 재시도하고 재실행한다.
package update

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Info — 서버 latest 매니페스트.
type Info struct {
	Version   string `json:"version"`
	Filename  string `json:"filename"`
	SHA256    string `json:"sha256"`
	SizeBytes int64  `json:"size_bytes"`
	Notes     string `json:"notes"`
}

var client = &http.Client{Timeout: 60 * time.Second}

// apiBase — 서버 URL(베이스) → "<base>/api/v1". 전체 경로를 넣어도 정리한다.
func apiBase(serverURL string) string {
	s := strings.TrimRight(strings.TrimSpace(serverURL), "/")
	if s == "" {
		return ""
	}
	if i := strings.Index(s, "/api/v1"); i >= 0 {
		return s[:i] + "/api/v1"
	}
	return s + "/api/v1"
}

// CheckLatest — 최신 버전을 조회해 현재보다 높으면 Info, 아니면 nil.
func CheckLatest(serverURL, currentVersion string) (*Info, error) {
	base := apiBase(serverURL)
	if base == "" {
		return nil, fmt.Errorf("서버 URL이 비어 있습니다")
	}
	resp, err := client.Get(base + "/app/latest?platform=windows")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, nil // 등록된 windows 릴리즈 없음 — 조용히 통과
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("latest 조회 실패 (HTTP %d)", resp.StatusCode)
	}
	var info Info
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&info); err != nil {
		return nil, err
	}
	if !newerVersion(info.Version, currentVersion) {
		return nil, nil
	}
	return &info, nil
}

// newerVersion — a 가 b 보다 높은 semver 인지 (숫자 필드 단위 비교).
func newerVersion(a, b string) bool {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var na, nb int
		if i < len(pa) {
			na, _ = strconv.Atoi(strings.TrimSpace(pa[i]))
		}
		if i < len(pb) {
			nb, _ = strconv.Atoi(strings.TrimSpace(pb[i]))
		}
		if na != nb {
			return na > nb
		}
	}
	return false
}

// DownloadAndApply — 아티팩트 다운로드 → SHA256 검증 → 새 exe 저장 →
// 교체 스크립트 실행. 성공 시 호출부는 즉시 앱을 종료해야 한다
// (스크립트가 종료를 기다렸다가 exe 를 바꿔치기하고 재실행한다).
func DownloadAndApply(serverURL string, info Info) error {
	if runtime.GOOS != "windows" {
		return fmt.Errorf("자동 업데이트는 Windows 빌드에서만 동작합니다")
	}
	base := apiBase(serverURL)
	resp, err := client.Get(base + "/app/download/" + url.PathEscape(info.Version) + "?platform=windows")
	if err != nil {
		return fmt.Errorf("다운로드 실패: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("다운로드 실패 (HTTP %d)", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 512<<20))
	if err != nil {
		return fmt.Errorf("다운로드 실패: %w", err)
	}

	digest := sha256.Sum256(data)
	if !strings.EqualFold(hex.EncodeToString(digest[:]), info.SHA256) {
		return fmt.Errorf("SHA256 불일치 — 손상된 아티팩트")
	}

	exeBytes, err := extractExe(data, info.Filename)
	if err != nil {
		return err
	}

	exePath, err := os.Executable()
	if err != nil {
		return err
	}
	exePath, _ = filepath.EvalSymlinks(exePath)
	newPath := exePath + ".new"
	if err := os.WriteFile(newPath, exeBytes, 0o755); err != nil {
		return fmt.Errorf("새 실행 파일 저장 실패: %w", err)
	}

	return spawnSwapScript(exePath, newPath)
}

// extractExe — zip 이면 현재 아키텍처에 맞는 exe 항목을, 아니면 그대로.
func extractExe(data []byte, filename string) ([]byte, error) {
	if !strings.HasSuffix(strings.ToLower(filename), ".zip") {
		return data, nil // 단일 exe 아티팩트
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("zip 해제 실패: %w", err)
	}
	var fallback *zip.File
	for _, f := range zr.File {
		name := strings.ToLower(filepath.Base(f.Name))
		if !strings.HasSuffix(name, ".exe") {
			continue
		}
		if strings.Contains(name, runtime.GOARCH) {
			return readZipFile(f)
		}
		if fallback == nil {
			fallback = f
		}
	}
	if fallback != nil {
		return readZipFile(fallback)
	}
	return nil, fmt.Errorf("zip 안에 exe 가 없습니다")
}

func readZipFile(f *zip.File) ([]byte, error) {
	rc, err := f.Open()
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(io.LimitReader(rc, 512<<20))
}

// spawnSwapScript — 프로세스 종료 후 exe 를 교체·재실행하는 배치를 백그라운드로 띄운다.
// move 는 우리가 종료할 때까지 실패하므로 재시도 루프가 대기를 겸한다.
func spawnSwapScript(exePath, newPath string) error {
	script := fmt.Sprintf(`@echo off
set RETRIES=60
:loop
move /y "%s" "%s" >nul 2>&1 && goto done
set /a RETRIES-=1
if %%RETRIES%% LEQ 0 goto cleanup
ping -n 2 127.0.0.1 >nul
goto loop
:done
start "" "%s"
:cleanup
del "%%~f0"
`, newPath, exePath, exePath)

	batPath := filepath.Join(os.TempDir(), "amon-update.bat")
	if err := os.WriteFile(batPath, []byte(script), 0o755); err != nil {
		return err
	}
	// 콘솔 창 없이 분리 실행 — 앱 종료 후에도 살아서 교체를 수행한다.
	cmd := exec.Command("cmd", "/c", "start", "/min", "", batPath)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("업데이트 스크립트 실행 실패: %w", err)
	}
	return nil
}
