//go:build windows && installer

package main

import (
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows/registry"
)

//go:embed payload/A-mon.exe
var application []byte

var version = "dev"

const uninstallKey = `Software\Microsoft\Windows\CurrentVersion\Uninstall\A-mon`

var messageBoxW = syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW")

func main() {
	silent := hasArg("--silent")
	if hasArg("--uninstall") {
		uninstall()
		return
	}
	if !silent && messageBox("A-mon을 이 컴퓨터에 설치할까요?\n\n설치 위치: 사용자 앱 폴더", "A-mon 설치", 0x21) != 1 {
		return
	}
	if err := install(); err != nil {
		if !silent {
			messageBox("설치하지 못했습니다.\n\n"+err.Error(), "A-mon 설치", 0x10)
		}
		return
	}
	if !silent {
		messageBox("A-mon 설치가 완료되었습니다.\n\n트레이에서 바로 사용할 수 있습니다.", "A-mon", 0x40)
	}
}

func install() error {
	local := os.Getenv("LOCALAPPDATA")
	if local == "" {
		return fmt.Errorf("LOCALAPPDATA를 찾을 수 없습니다")
	}
	dir := filepath.Join(local, "Programs", "A-mon")
	app := filepath.Join(dir, "A-mon.exe")
	uninstaller := filepath.Join(dir, "Uninstall.exe")
	_ = exec.Command("taskkill", "/IM", "A-mon.exe", "/F").Run()
	time.Sleep(350 * time.Millisecond)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(app, application, 0o755); err != nil {
		return err
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	if err := copyFile(self, uninstaller); err != nil {
		return err
	}
	startMenu := filepath.Join(os.Getenv("APPDATA"), "Microsoft", "Windows", "Start Menu", "Programs", "A-mon.lnk")
	startup := filepath.Join(os.Getenv("APPDATA"), "Microsoft", "Windows", "Start Menu", "Programs", "Startup", "A-mon.lnk")
	if err := createShortcut(app, startMenu); err != nil {
		return err
	}
	if err := createShortcut(app, startup); err != nil {
		return err
	}
	if err := registerUninstaller(uninstaller, app, dir); err != nil {
		return err
	}
	return exec.Command(app).Start()
}

func uninstall() {
	if !hasArg("--silent") && messageBox("A-mon과 시작 프로그램 등록을 제거할까요?", "A-mon 제거", 0x21) != 1 {
		return
	}
	_ = exec.Command("taskkill", "/IM", "A-mon.exe", "/F").Run()
	links := []string{
		filepath.Join(os.Getenv("APPDATA"), "Microsoft", "Windows", "Start Menu", "Programs", "A-mon.lnk"),
		filepath.Join(os.Getenv("APPDATA"), "Microsoft", "Windows", "Start Menu", "Programs", "Startup", "A-mon.lnk"),
	}
	for _, link := range links {
		_ = os.Remove(link)
	}
	_ = registry.DeleteKey(registry.CURRENT_USER, uninstallKey)
	self, _ := os.Executable()
	dir := filepath.Dir(self)
	expected := filepath.Clean(filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs", "A-mon"))
	if filepath.Clean(dir) == expected {
		quoted := strings.ReplaceAll(dir, "'", "''")
		script := fmt.Sprintf("Wait-Process -Id %d -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 400; Remove-Item -LiteralPath '%s' -Recurse -Force", os.Getpid(), quoted)
		_ = exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", script).Start()
	}
	if !hasArg("--silent") {
		messageBox("A-mon을 제거했습니다.\n사용 기록과 설정은 보존됩니다.", "A-mon", 0x40)
	}
}

func registerUninstaller(uninstaller, app, dir string) error {
	key, _, err := registry.CreateKey(registry.CURRENT_USER, uninstallKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	values := map[string]string{
		"DisplayName": "A-mon", "DisplayVersion": version, "Publisher": "A-mon",
		"DisplayIcon": app, "InstallLocation": dir, "UninstallString": `"` + uninstaller + `" --uninstall`,
		"QuietUninstallString": `"` + uninstaller + `" --uninstall --silent`,
	}
	for name, value := range values {
		if err := key.SetStringValue(name, value); err != nil {
			return err
		}
	}
	return key.SetDWordValue("NoModify", 1)
}

func createShortcut(target, destination string) error {
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	quote := func(value string) string { return strings.ReplaceAll(value, "'", "''") }
	script := fmt.Sprintf("$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%s');$s.TargetPath='%s';$s.WorkingDirectory='%s';$s.IconLocation='%s,0';$s.Save()", quote(destination), quote(target), quote(filepath.Dir(target)), quote(target))
	return exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script).Run()
}

func copyFile(source, destination string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	return os.WriteFile(destination, data, 0o755)
}

func hasArg(value string) bool {
	for _, arg := range os.Args[1:] {
		if strings.EqualFold(arg, value) {
			return true
		}
	}
	return false
}

func messageBox(message, title string, flags uintptr) int {
	m, _ := syscall.UTF16PtrFromString(message)
	t, _ := syscall.UTF16PtrFromString(title)
	result, _, _ := messageBoxW.Call(0, uintptr(unsafe.Pointer(m)), uintptr(unsafe.Pointer(t)), flags)
	return int(result)
}
