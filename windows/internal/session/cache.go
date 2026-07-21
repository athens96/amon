package session

import (
	"encoding/json"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

// 파일 단위 세션 파싱 캐시 (맥 SessionFileCache 이식, 디스크 영속).
//
// 세션 로그는 닫히면 불변이라, 지문(mtime+size)이 같은 파일은 앱을 재시작해도
// 다시 읽지 않는다 — 콜드 스캔 비용을 첫 실행 한 번으로 억제한다.

const fileCacheVersion = 1

// CacheEntry — 파일 하나의 파싱 결과. Record 가 nil 이면 "파싱했지만 세션이
// 아님"(토큰도 요청도 없음) — 이것도 기억해 재읽기를 막는다.
type CacheEntry struct {
	Signature string  `json:"signature"`
	Record    *Record `json:"record,omitempty"`
}

// FileCache — path → CacheEntry. 저장 파일은 cache/session-files.json.
type FileCache struct {
	Version int                    `json:"version"`
	Entries map[string]*CacheEntry `json:"entries"`

	path  string
	dirty bool
	mu    sync.Mutex
}

// LoadFileCache — 캐시 파일을 읽는다. 없거나 버전이 다르면 빈 캐시.
func LoadFileCache(path string) *FileCache {
	c := &FileCache{Version: fileCacheVersion, Entries: map[string]*CacheEntry{}, path: path}
	data, err := os.ReadFile(path)
	if err != nil {
		return c
	}
	var loaded FileCache
	if json.Unmarshal(data, &loaded) != nil || loaded.Version != fileCacheVersion {
		return c
	}
	if loaded.Entries != nil {
		c.Entries = loaded.Entries
	}
	return c
}

// Save — 변경이 있었을 때만 원자적으로 쓴다.
func (c *FileCache) Save() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.dirty || c.path == "" {
		return
	}
	data, err := json.Marshal(c)
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(c.path), 0o755)
	tmp := c.path + ".tmp"
	if os.WriteFile(tmp, data, 0o644) == nil {
		_ = os.Rename(tmp, c.path)
		c.dirty = false
	}
}

func (c *FileCache) get(key, signature string) (*CacheEntry, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.Entries[key]
	if !ok || entry.Signature != signature {
		return nil, false
	}
	return entry, true
}

func (c *FileCache) put(key string, entry *CacheEntry) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.Entries[key] = entry
	c.dirty = true
}

// sweep — 이번 스캔에서 보이지 않은 prefix 키 제거(삭제된 파일·루트 변경).
func (c *FileCache) sweep(prefix string, visited map[string]struct{}) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for key := range c.Entries {
		if len(key) < len(prefix) || key[:len(prefix)] != prefix {
			continue
		}
		if _, ok := visited[key]; !ok {
			delete(c.Entries, key)
			c.dirty = true
		}
	}
}

// fileSetSignature — 파일 집합의 (path, size, mtime) 지문. 맥과 같은 FNV-1a.
func fileSetSignature(paths []string) string {
	parts := make([]string, 0, len(paths))
	for _, p := range paths {
		st, err := os.Stat(p)
		if err != nil {
			parts = append(parts, fmt.Sprintf("%s|-1|0", p))
			continue
		}
		parts = append(parts, fmt.Sprintf("%s|%d|%d", p, st.Size(), st.ModTime().UnixNano()))
	}
	sort.Strings(parts)
	h := fnv.New64a()
	for i, part := range parts {
		if i > 0 {
			h.Write([]byte{'\n'})
		}
		h.Write([]byte(part))
	}
	return fmt.Sprintf("%x", h.Sum64())
}
