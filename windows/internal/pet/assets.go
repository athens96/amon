// Package pet contains the platform-independent parts of the Windows desktop pet.
package pet

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"image/png"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

const (
	MaxArchiveBytes   int64 = 40 * 1024 * 1024
	MaxArchiveEntries       = 256
	MaxManifestBytes  int64 = 64 * 1024
	MaxSpriteBytes    int64 = 20 * 1024 * 1024
	RequiredWidth           = 1536
	RequiredHeight          = 1872
)

var (
	ErrArchiveTooLarge   = errors.New("pet archive is too large")
	ErrInvalidArchive    = errors.New("invalid pet archive")
	ErrTooManyEntries    = errors.New("pet archive has too many entries")
	ErrUnsafePath        = errors.New("unsafe archive path")
	ErrDuplicateEntry    = errors.New("duplicate archive entry")
	ErrAmbiguousManifest = errors.New("pet archive has multiple pet.json manifests")
	ErrManifestTooLarge  = errors.New("pet.json is too large")
	ErrInvalidManifest   = errors.New("invalid pet.json")
	ErrMissingSprite     = errors.New("spritesheet.png is missing")
	ErrAmbiguousSprite   = errors.New("multiple spritesheet.png files found")
	ErrSpriteNotFound    = errors.New("manifest sprite was not found")
	ErrSpriteTooLarge    = errors.New("pet sprite is too large")
	ErrUnsupportedFormat = errors.New("unsupported pet asset format")
	ErrUnsupportedWebP   = errors.New("WebP pet assets are not supported on Windows")
	ErrUnreadablePNG     = errors.New("unreadable PNG sprite")
	ErrInvalidDimensions = errors.New("pet sprite must be 1536x1872")
	ErrMissingAlpha      = errors.New("pet sprite must contain an alpha channel")
)

var (
	pngSignature  = []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}
	zipSignatures = [][4]byte{
		{'P', 'K', 0x03, 0x04},
		{'P', 'K', 0x05, 0x06},
		{'P', 'K', 0x07, 0x08},
	}
)

// Asset is the validated, installable portion of a codex-pets package.
// Package previews and other files are intentionally never extracted.
type Asset struct {
	DisplayName string
	PNG         []byte
	Width       int
	Height      int
}

type manifest struct {
	DisplayName     string `json:"displayName"`
	SpritesheetPath string `json:"spritesheetPath"`
}

type archiveEntry struct {
	file       *zip.File
	normalized string
	directory  bool
	metadata   bool
}

// LoadAsset validates and reads either a standalone PNG or a codex-pets ZIP.
// ZIP packages are inspected in place; only pet.json and the selected sprite
// are read, with independent uncompressed-size limits.
func LoadAsset(source string) (*Asset, error) {
	info, err := os.Stat(source)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%w: source is not a regular file", ErrUnsupportedFormat)
	}

	header, err := readHeader(source, 12)
	if err != nil {
		return nil, err
	}
	if hasZIPSignature(header) {
		if info.Size() > MaxArchiveBytes {
			return nil, fmt.Errorf("%w: %d > %d bytes", ErrArchiveTooLarge, info.Size(), MaxArchiveBytes)
		}
		return loadZIP(source)
	}
	if strings.EqualFold(filepath.Ext(source), ".zip") {
		return nil, ErrInvalidArchive
	}
	if info.Size() > MaxSpriteBytes {
		return nil, fmt.Errorf("%w: %d > %d bytes", ErrSpriteTooLarge, info.Size(), MaxSpriteBytes)
	}
	data, err := readFileLimited(source, MaxSpriteBytes)
	if err != nil {
		return nil, err
	}
	return validatePNG(data, "")
}

// InstallAsset validates source and replaces destinationFile with only the
// selected PNG. The temporary file is created beside the destination so the
// final rename remains on the same volume. On Windows, where replacing an
// existing destination may fail, replaceFile performs a rollback-safe rename.
func InstallAsset(source, destinationFile string) (*Asset, error) {
	asset, err := LoadAsset(source)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(destinationFile) == "" {
		return nil, errors.New("pet destination is empty")
	}
	directory := filepath.Dir(destinationFile)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return nil, err
	}
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(destinationFile)+".tmp-*")
	if err != nil {
		return nil, err
	}
	temporaryPath := temporary.Name()
	keepTemporary := true
	defer func() {
		if keepTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()

	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return nil, err
	}
	if _, err := temporary.Write(asset.PNG); err != nil {
		_ = temporary.Close()
		return nil, err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return nil, err
	}
	if err := temporary.Close(); err != nil {
		return nil, err
	}
	if err := replaceFile(temporaryPath, destinationFile); err != nil {
		return nil, err
	}
	keepTemporary = false
	return asset, nil
}

func loadZIP(source string) (*Asset, error) {
	reader, err := zip.OpenReader(source)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidArchive, err)
	}
	defer reader.Close()

	if len(reader.File) > MaxArchiveEntries {
		return nil, fmt.Errorf("%w: %d > %d", ErrTooManyEntries, len(reader.File), MaxArchiveEntries)
	}
	entries := make([]archiveEntry, 0, len(reader.File))
	byName := make(map[string]archiveEntry, len(reader.File))
	seen := make(map[string]string, len(reader.File))
	for _, file := range reader.File {
		normalized, directory, err := normalizeArchivePath(file.Name, file.FileInfo().IsDir())
		if err != nil {
			return nil, err
		}
		duplicateKey := strings.ToLower(normalized)
		if previous, exists := seen[duplicateKey]; exists {
			return nil, fmt.Errorf("%w: %q conflicts with %q", ErrDuplicateEntry, normalized, previous)
		}
		seen[duplicateKey] = normalized
		if file.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("%w: symlink %q", ErrUnsafePath, file.Name)
		}
		entry := archiveEntry{
			file:       file,
			normalized: normalized,
			directory:  directory,
			metadata:   isMetadataPath(normalized),
		}
		entries = append(entries, entry)
		byName[duplicateKey] = entry
	}

	var manifests []archiveEntry
	for _, entry := range entries {
		if !entry.directory && !entry.metadata && strings.EqualFold(path.Base(entry.normalized), "pet.json") {
			manifests = append(manifests, entry)
		}
	}
	if len(manifests) > 1 {
		return nil, ErrAmbiguousManifest
	}

	selected := archiveEntry{}
	displayName := ""
	if len(manifests) == 1 {
		data, err := readZIPEntry(manifests[0].file, MaxManifestBytes, ErrManifestTooLarge)
		if err != nil {
			return nil, err
		}
		var pet manifest
		if err := json.Unmarshal(data, &pet); err != nil || strings.TrimSpace(pet.SpritesheetPath) == "" {
			return nil, fmt.Errorf("%w: spritesheetPath is required", ErrInvalidManifest)
		}
		relativeSpritePath, _, err := normalizeArchivePath(strings.TrimSpace(pet.SpritesheetPath), false)
		if err != nil {
			return nil, err
		}
		spritePath := path.Join(path.Dir(manifests[0].normalized), relativeSpritePath)
		entry, found := byName[strings.ToLower(spritePath)]
		if !found || entry.directory || entry.metadata {
			return nil, fmt.Errorf("%w: %s", ErrSpriteNotFound, spritePath)
		}
		selected = entry
		displayName = sanitizeDisplayName(pet.DisplayName)
	} else {
		var candidates []archiveEntry
		var hasWebP bool
		for _, entry := range entries {
			if entry.directory || entry.metadata {
				continue
			}
			switch strings.ToLower(path.Base(entry.normalized)) {
			case "spritesheet.png":
				candidates = append(candidates, entry)
			case "spritesheet.webp":
				hasWebP = true
			}
		}
		if len(candidates) == 0 {
			if hasWebP {
				return nil, ErrUnsupportedWebP
			}
			return nil, ErrMissingSprite
		}
		if len(candidates) > 1 {
			return nil, ErrAmbiguousSprite
		}
		selected = candidates[0]
	}

	sprite, err := readZIPEntry(selected.file, MaxSpriteBytes, ErrSpriteTooLarge)
	if err != nil {
		return nil, err
	}
	return validatePNG(sprite, displayName)
}

func normalizeArchivePath(name string, directoryHint bool) (string, bool, error) {
	if name == "" || len(name) > 4096 || strings.ContainsRune(name, '\x00') ||
		strings.ContainsRune(name, '\\') || strings.HasPrefix(name, "/") {
		return "", false, fmt.Errorf("%w: %q", ErrUnsafePath, name)
	}
	directory := directoryHint || strings.HasSuffix(name, "/")
	trimmed := strings.TrimSuffix(name, "/")
	if trimmed == "" {
		return "", false, fmt.Errorf("%w: %q", ErrUnsafePath, name)
	}
	rawParts := strings.Split(trimmed, "/")
	parts := make([]string, 0, len(rawParts))
	for _, part := range rawParts {
		switch {
		case part == "", part == "..":
			return "", false, fmt.Errorf("%w: %q", ErrUnsafePath, name)
		case part == ".":
			continue
		case strings.ContainsRune(part, ':'):
			return "", false, fmt.Errorf("%w: %q", ErrUnsafePath, name)
		case strings.HasSuffix(part, ".") || strings.HasSuffix(part, " "):
			return "", false, fmt.Errorf("%w: %q", ErrUnsafePath, name)
		default:
			parts = append(parts, part)
		}
	}
	if len(parts) == 0 {
		return "", false, fmt.Errorf("%w: %q", ErrUnsafePath, name)
	}
	return strings.Join(parts, "/"), directory, nil
}

func isMetadataPath(name string) bool {
	parts := strings.Split(name, "/")
	for _, part := range parts {
		if strings.EqualFold(part, "__MACOSX") {
			return true
		}
	}
	return strings.HasPrefix(path.Base(name), "._")
}

func readZIPEntry(file *zip.File, limit int64, limitError error) ([]byte, error) {
	if file.UncompressedSize64 > uint64(limit) {
		return nil, fmt.Errorf("%w: %d > %d bytes", limitError, file.UncompressedSize64, limit)
	}
	reader, err := file.Open()
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidArchive, err)
	}
	defer reader.Close()
	data, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidArchive, err)
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%w: more than %d bytes", limitError, limit)
	}
	return data, nil
}

func validatePNG(data []byte, displayName string) (*Asset, error) {
	if int64(len(data)) > MaxSpriteBytes {
		return nil, fmt.Errorf("%w: %d > %d bytes", ErrSpriteTooLarge, len(data), MaxSpriteBytes)
	}
	if isWebP(data) {
		return nil, ErrUnsupportedWebP
	}
	if !bytes.HasPrefix(data, pngSignature) {
		return nil, ErrUnsupportedFormat
	}
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnreadablePNG, err)
	}
	if config.Width != RequiredWidth || config.Height != RequiredHeight {
		return nil, fmt.Errorf("%w: got %dx%d", ErrInvalidDimensions, config.Width, config.Height)
	}
	decoded, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnreadablePNG, err)
	}
	if decoded.Bounds().Dx() != RequiredWidth || decoded.Bounds().Dy() != RequiredHeight {
		return nil, fmt.Errorf("%w: decoded %dx%d", ErrInvalidDimensions, decoded.Bounds().Dx(), decoded.Bounds().Dy())
	}
	if !pngContainsAlpha(data) {
		return nil, ErrMissingAlpha
	}
	return &Asset{
		DisplayName: displayName,
		PNG:         data,
		Width:       config.Width,
		Height:      config.Height,
	}, nil
}

func pngContainsAlpha(data []byte) bool {
	if len(data) < 33 || !bytes.Equal(data[12:16], []byte("IHDR")) {
		return false
	}
	colorType := data[25]
	if colorType == 4 || colorType == 6 {
		return true
	}
	for offset := 8; offset+12 <= len(data); {
		length := int64(binary.BigEndian.Uint32(data[offset : offset+4]))
		end := int64(offset) + 12 + length
		if end > int64(len(data)) || end < int64(offset) {
			return false
		}
		chunkType := string(data[offset+4 : offset+8])
		if chunkType == "tRNS" {
			return true
		}
		if chunkType == "IDAT" || chunkType == "IEND" {
			return false
		}
		offset = int(end)
	}
	return false
}

func readHeader(fileName string, count int64) ([]byte, error) {
	file, err := os.Open(fileName)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return io.ReadAll(io.LimitReader(file, count))
}

func readFileLimited(fileName string, limit int64) ([]byte, error) {
	file, err := os.Open(fileName)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%w: more than %d bytes", ErrSpriteTooLarge, limit)
	}
	return data, nil
}

func hasZIPSignature(data []byte) bool {
	if len(data) < 4 {
		return false
	}
	var prefix [4]byte
	copy(prefix[:], data[:4])
	for _, signature := range zipSignatures {
		if prefix == signature {
			return true
		}
	}
	return false
}

func isWebP(data []byte) bool {
	return len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP"
}

func sanitizeDisplayName(value string) string {
	value = strings.TrimSpace(strings.NewReplacer("\r", " ", "\n", " ").Replace(value))
	runes := []rune(value)
	if len(runes) > 80 {
		runes = runes[:80]
	}
	return string(runes)
}

func replaceFile(temporary, destination string) error {
	if err := os.Rename(temporary, destination); err == nil {
		return nil
	} else if _, statErr := os.Stat(destination); statErr != nil {
		return err
	}

	backupFile, err := os.CreateTemp(filepath.Dir(destination), "."+filepath.Base(destination)+".old-*")
	if err != nil {
		return err
	}
	backup := backupFile.Name()
	if err := backupFile.Close(); err != nil {
		_ = os.Remove(backup)
		return err
	}
	if err := os.Remove(backup); err != nil {
		return err
	}
	if err := os.Rename(destination, backup); err != nil {
		return err
	}
	if err := os.Rename(temporary, destination); err != nil {
		_ = os.Rename(backup, destination)
		return err
	}
	_ = os.Remove(backup)
	return nil
}
