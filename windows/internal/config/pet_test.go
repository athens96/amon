package config

import (
	"encoding/json"
	"testing"
)

func TestPetConfigBackwardCompatibleDefaults(t *testing.T) {
	var cfg Config
	if err := json.Unmarshal([]byte(`{"server_url":"","paths":{}}`), &cfg); err != nil {
		t.Fatal(err)
	}
	if !cfg.Pet.EnabledValue() {
		t.Fatal("pet should default to enabled")
	}
	if cfg.Pet.LocalActivityEnabledValue() {
		t.Fatal("local activity should require explicit opt-in")
	}
	if !cfg.Pet.ShowsCurrentTaskValue() {
		t.Fatal("task bubble should default to enabled")
	}
	if cfg.Pet.SpriteVersionValue() != 1 {
		t.Fatalf("sprite version = %d, want 1", cfg.Pet.SpriteVersionValue())
	}
}

func TestPetConfigPreservesExplicitFalse(t *testing.T) {
	cfg := Config{Pet: PetConfig{
		Enabled:              Bool(false),
		LocalActivityEnabled: Bool(true),
		ShowsCurrentTask:     Bool(false),
		SpriteVersion:        2,
		PositionX:            Int(24),
		PositionY:            Int(48),
	}}
	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	var decoded Config
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Pet.EnabledValue() {
		t.Fatal("explicit disabled state was lost")
	}
	if !decoded.Pet.LocalActivityEnabledValue() {
		t.Fatal("local activity opt-in was lost")
	}
	if decoded.Pet.ShowsCurrentTaskValue() {
		t.Fatal("explicit hidden task bubble was lost")
	}
	if decoded.Pet.SpriteVersionValue() != 2 {
		t.Fatalf("sprite version = %d, want 2", decoded.Pet.SpriteVersionValue())
	}
	if decoded.Pet.PositionX == nil || *decoded.Pet.PositionX != 24 {
		t.Fatal("position x was lost")
	}
}
