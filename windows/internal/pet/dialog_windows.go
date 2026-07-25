//go:build windows

package pet

import (
	"errors"
	"fmt"
	"syscall"
	"unsafe"
)

var (
	comdlg32           = syscall.NewLazyDLL("comdlg32.dll")
	pGetOpenFileName   = comdlg32.NewProc("GetOpenFileNameW")
	pCommDlgError      = comdlg32.NewProc("CommDlgExtendedError")
	ErrDialogCancelled = errors.New("pet file selection cancelled")
)

type openFileName struct {
	StructSize       uint32
	Owner            uintptr
	Instance         uintptr
	Filter           *uint16
	CustomFilter     *uint16
	MaxCustomFilter  uint32
	FilterIndex      uint32
	File             *uint16
	MaxFile          uint32
	FileTitle        *uint16
	MaxFileTitle     uint32
	InitialDirectory *uint16
	Title            *uint16
	Flags            uint32
	FileOffset       uint16
	FileExtension    uint16
	DefaultExtension *uint16
	CustomData       uintptr
	Hook             uintptr
	TemplateName     *uint16
	Reserved         uintptr
	Reserved2        uint32
	FlagsEx          uint32
}

func SelectPetFile() (string, error) {
	filter := make([]uint16, 0, 96)
	for _, part := range []string{
		"Codex 펫 (*.zip;*.png)", "*.zip;*.png",
		"PNG (*.png)", "*.png",
		"모든 파일", "*.*",
	} {
		encoded, _ := syscall.UTF16FromString(part)
		filter = append(filter, encoded...)
	}
	filter = append(filter, 0)
	title, _ := syscall.UTF16PtrFromString("Codex 호환 펫 가져오기")
	defaultExtension, _ := syscall.UTF16PtrFromString("zip")
	buffer := make([]uint16, 32768)
	dialog := openFileName{
		StructSize: uint32(unsafe.Sizeof(openFileName{})),
		Filter:     &filter[0], FilterIndex: 1,
		File: &buffer[0], MaxFile: uint32(len(buffer)),
		Title: title, DefaultExtension: defaultExtension,
		Flags: 0x00001000 | 0x00000800 | 0x00080000,
	}
	ok, _, _ := pGetOpenFileName.Call(uintptr(unsafe.Pointer(&dialog)))
	if ok == 0 {
		code, _, _ := pCommDlgError.Call()
		if code != 0 {
			return "", fmt.Errorf("pet file dialog failed (0x%x)", code)
		}
		return "", ErrDialogCancelled
	}
	return syscall.UTF16ToString(buffer), nil
}
