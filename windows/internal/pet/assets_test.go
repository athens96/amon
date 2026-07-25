package pet

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadAssetPixelCoderFixture(t *testing.T) {
	sprite := testPNG(t, RequiredWidth, RequiredHeight, true)
	manifest, err := json.Marshal(map[string]any{
		"id":              "pixel-coder",
		"displayName":     "Pixel Coder",
		"spritesheetPath": "spritesheet.png",
	})
	if err != nil {
		t.Fatal(err)
	}
	archive := testZIP(t, []zipFixture{
		{name: "pixel-coder/"},
		{name: "pixel-coder/preview.png", data: []byte("not the sprite")},
		{name: "pixel-coder/pet.json", data: manifest},
		{name: "pixel-coder/spritesheet.png", data: sprite},
		{name: "__MACOSX/pixel-coder/._pet.json", data: []byte("metadata")},
		{name: "pixel-coder/._spritesheet.png", data: []byte("metadata")},
	})

	asset, err := LoadAsset(archive)
	if err != nil {
		t.Fatal(err)
	}
	if asset.DisplayName != "Pixel Coder" {
		t.Fatalf("DisplayName = %q", asset.DisplayName)
	}
	if asset.Width != RequiredWidth || asset.Height != RequiredHeight {
		t.Fatalf("dimensions = %dx%d", asset.Width, asset.Height)
	}
	if !bytes.Equal(asset.PNG, sprite) {
		t.Fatal("selected PNG differs from manifest sprite")
	}
}

func TestLoadAssetExternalPixelCoderArchive(t *testing.T) {
	source := os.Getenv("AMON_CODEX_PET_TEST_ARCHIVE")
	if source == "" {
		t.Skip("AMON_CODEX_PET_TEST_ARCHIVE is not set")
	}
	asset, err := LoadAsset(source)
	if err != nil {
		t.Fatal(err)
	}
	if asset.Width != RequiredWidth || asset.Height != RequiredHeight {
		t.Fatalf("dimensions = %dx%d", asset.Width, asset.Height)
	}
	if len(asset.PNG) == 0 {
		t.Fatal("external archive returned an empty sprite")
	}
}

func TestLoadAssetStandalonePNG(t *testing.T) {
	source := filepath.Join(t.TempDir(), "custom.data")
	sprite := testPNG(t, RequiredWidth, RequiredHeight, true)
	if err := os.WriteFile(source, sprite, 0o600); err != nil {
		t.Fatal(err)
	}
	asset, err := LoadAsset(source)
	if err != nil {
		t.Fatal(err)
	}
	if asset.DisplayName != "" || !bytes.Equal(asset.PNG, sprite) {
		t.Fatal("standalone PNG was not preserved")
	}
}

func TestLoadAssetUsesUniqueFallbackSprite(t *testing.T) {
	sprite := testPNG(t, RequiredWidth, RequiredHeight, true)
	archive := testZIP(t, []zipFixture{
		{name: "pet/readme.txt", data: []byte("hello")},
		{name: "pet/spritesheet.png", data: sprite},
		{name: "pet/preview.png", data: []byte("not a png")},
	})
	asset, err := LoadAsset(archive)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(asset.PNG, sprite) {
		t.Fatal("fallback sprite was not selected")
	}
}

func TestLoadAssetRejectsUnsafeAndDuplicatePaths(t *testing.T) {
	tests := []struct {
		name    string
		entries []zipFixture
		want    error
	}{
		{
			name: "traversal",
			entries: []zipFixture{
				{name: "../spritesheet.png", data: []byte("x")},
			},
			want: ErrUnsafePath,
		},
		{
			name: "windows separator",
			entries: []zipFixture{
				{name: `pet\spritesheet.png`, data: []byte("x")},
			},
			want: ErrUnsafePath,
		},
		{
			name: "case folded duplicate",
			entries: []zipFixture{
				{name: "pet/SPRITESHEET.png", data: []byte("x")},
				{name: "PET/spritesheet.PNG", data: []byte("y")},
			},
			want: ErrDuplicateEntry,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := LoadAsset(testZIP(t, test.entries))
			if !errors.Is(err, test.want) {
				t.Fatalf("error = %v, want %v", err, test.want)
			}
		})
	}
}

func TestLoadAssetRejectsAmbiguousManifestAndSprite(t *testing.T) {
	sprite := testPNG(t, RequiredWidth, RequiredHeight, true)
	t.Run("manifest", func(t *testing.T) {
		archive := testZIP(t, []zipFixture{
			{name: "a/pet.json", data: []byte(`{"spritesheetPath":"spritesheet.png"}`)},
			{name: "b/pet.json", data: []byte(`{"spritesheetPath":"spritesheet.png"}`)},
		})
		if _, err := LoadAsset(archive); !errors.Is(err, ErrAmbiguousManifest) {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("sprite", func(t *testing.T) {
		archive := testZIP(t, []zipFixture{
			{name: "a/spritesheet.png", data: sprite},
			{name: "b/spritesheet.png", data: sprite},
		})
		if _, err := LoadAsset(archive); !errors.Is(err, ErrAmbiguousSprite) {
			t.Fatalf("error = %v", err)
		}
	})
}

func TestLoadAssetRejectsManifestPathTraversal(t *testing.T) {
	archive := testZIP(t, []zipFixture{
		{name: "pixel-coder/pet.json", data: []byte(`{"spritesheetPath":"../spritesheet.png"}`)},
		{name: "spritesheet.png", data: testPNG(t, RequiredWidth, RequiredHeight, true)},
	})
	if _, err := LoadAsset(archive); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("error = %v, want %v", err, ErrUnsafePath)
	}
}

func TestLoadAssetRejectsArchiveLimits(t *testing.T) {
	t.Run("entry count", func(t *testing.T) {
		entries := make([]zipFixture, MaxArchiveEntries+1)
		for i := range entries {
			entries[i] = zipFixture{name: strings.Repeat("a", i%20+1) + "/" + strings.Repeat("b", i/20+1)}
		}
		if _, err := LoadAsset(testZIP(t, entries)); !errors.Is(err, ErrTooManyEntries) {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("manifest bytes", func(t *testing.T) {
		archive := testZIP(t, []zipFixture{
			{name: "pet.json", data: bytes.Repeat([]byte(" "), int(MaxManifestBytes)+1)},
		})
		if _, err := LoadAsset(archive); !errors.Is(err, ErrManifestTooLarge) {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("sprite bytes", func(t *testing.T) {
		archive := testZIP(t, []zipFixture{
			{name: "spritesheet.png", data: bytes.Repeat([]byte{0}, int(MaxSpriteBytes)+1)},
		})
		if _, err := LoadAsset(archive); !errors.Is(err, ErrSpriteTooLarge) {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("archive bytes", func(t *testing.T) {
		file := filepath.Join(t.TempDir(), "large.zip")
		if err := os.WriteFile(file, []byte{'P', 'K', 0x03, 0x04}, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Truncate(file, MaxArchiveBytes+1); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadAsset(file); !errors.Is(err, ErrArchiveTooLarge) {
			t.Fatalf("error = %v", err)
		}
	})
}

func TestLoadAssetRejectsInvalidImages(t *testing.T) {
	tests := []struct {
		name string
		data []byte
		want error
	}{
		{name: "WebP", data: append(append([]byte("RIFF"), make([]byte, 4)...), []byte("WEBP")...), want: ErrUnsupportedWebP},
		{name: "unsupported", data: []byte{0xff, 0xd8, 0xff, 0xe0}, want: ErrUnsupportedFormat},
		{name: "truncated PNG", data: pngSignature, want: ErrUnreadablePNG},
		{name: "corrupt pixel data", data: corruptPNG(t, testPNG(t, RequiredWidth, RequiredHeight, true)), want: ErrUnreadablePNG},
		{name: "wrong size", data: testPNG(t, 32, 48, true), want: ErrInvalidDimensions},
		{name: "opaque", data: testPNG(t, RequiredWidth, RequiredHeight, false), want: ErrMissingAlpha},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			file := filepath.Join(t.TempDir(), "asset")
			if err := os.WriteFile(file, test.data, 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := LoadAsset(file); !errors.Is(err, test.want) {
				t.Fatalf("error = %v, want %v", err, test.want)
			}
		})
	}
}

func corruptPNG(t *testing.T, data []byte) []byte {
	t.Helper()
	corrupt := append([]byte(nil), data...)
	index := bytes.Index(corrupt, []byte("IDAT"))
	if index < 0 || index+5 >= len(corrupt) {
		t.Fatal("test PNG does not contain IDAT data")
	}
	corrupt[index+4] ^= 0xff
	return corrupt
}

func TestInstallAssetAtomicallyReplacesDestination(t *testing.T) {
	source := filepath.Join(t.TempDir(), "sprite.png")
	sprite := testPNG(t, RequiredWidth, RequiredHeight, true)
	if err := os.WriteFile(source, sprite, 0o600); err != nil {
		t.Fatal(err)
	}
	destinationDirectory := filepath.Join(t.TempDir(), "nested", "pet")
	destination := filepath.Join(destinationDirectory, "spritesheet.png")
	if err := os.MkdirAll(destinationDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destination, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}

	asset, err := InstallAsset(source, destination)
	if err != nil {
		t.Fatal(err)
	}
	installed, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(installed, sprite) || !bytes.Equal(asset.PNG, sprite) {
		t.Fatal("destination was not replaced with validated PNG")
	}
	matches, err := filepath.Glob(filepath.Join(destinationDirectory, ".spritesheet.png.*-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Fatalf("temporary files remain: %v", matches)
	}
}

type zipFixture struct {
	name string
	data []byte
}

func testZIP(t *testing.T, entries []zipFixture) string {
	t.Helper()
	fileName := filepath.Join(t.TempDir(), "pixel-coder.zip")
	file, err := os.Create(fileName)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	for _, entry := range entries {
		header := &zip.FileHeader{Name: entry.name, Method: zip.Deflate}
		if strings.HasSuffix(entry.name, "/") {
			header.SetMode(os.ModeDir | 0o755)
		}
		part, err := writer.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := part.Write(entry.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	return fileName
}

func testPNG(t *testing.T, width, height int, alpha bool) []byte {
	t.Helper()
	var source image.Image
	if alpha {
		imageData := image.NewNRGBA(image.Rect(0, 0, width, height))
		for offset := 0; offset < len(imageData.Pix); offset += 4 {
			imageData.Pix[offset] = 80
			imageData.Pix[offset+1] = 190
			imageData.Pix[offset+2] = 110
			imageData.Pix[offset+3] = 210
		}
		source = imageData
	} else {
		source = image.NewRGBA(image.Rect(0, 0, width, height))
		drawColor := color.RGBA{R: 80, G: 190, B: 110, A: 255}
		for y := 0; y < height; y++ {
			for x := 0; x < width; x++ {
				source.(*image.RGBA).SetRGBA(x, y, drawColor)
			}
		}
	}
	var output bytes.Buffer
	if err := png.Encode(&output, source); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}
