//go:build !windows

package pet

import "errors"

var ErrDialogCancelled = errors.New("pet file selection is only available on Windows")

func SelectPetFile() (string, error) { return "", ErrDialogCancelled }
