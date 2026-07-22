package main

import (
	"os"
	"path/filepath"

	"github.com/athens96/amon/windows/internal/config"
	"github.com/athens96/amon/windows/internal/scan"
	"github.com/athens96/amon/windows/internal/session"
	"github.com/athens96/amon/windows/internal/store"
)

// dashSync — 에이전트 대시보드의 로컬 usage.db 저장 상태.
type dashSync struct {
	store *store.Store
}

// newDashSync — usage.db 를 연다. 열기 실패 시 nil.
func newDashSync() *dashSync {
	dir, err := config.Dir()
	if err != nil {
		return nil
	}
	st, err := store.Open(filepath.Join(dir, "usage.db"))
	if err != nil {
		return nil
	}
	return &dashSync{store: st}
}

func (d *dashSync) close() {
	if d != nil && d.store != nil {
		_ = d.store.Close()
	}
}

// persist — usage.db 에 스캔 결과를 저장한다.
func (d *dashSync) persist(summaries []scan.ToolSummary, records []session.Record) {
	if d == nil || d.store == nil {
		return
	}
	cfg, _ := config.Load()
	_ = d.store.Save(summaries, records, store.Meta{
		Machine:    hostname(),
		AppVersion: appVersion,
		DeviceID:   cfg.DeviceID,
	})
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "unknown"
	}
	return h
}
