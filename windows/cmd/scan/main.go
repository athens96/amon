// cmd/scan — GUI 없이 현재 OS 기본 경로(또는 config)로 사용량을 출력한다.
// macOS 개발 머신에서 Swift 앱(--scan)과의 스캐너 패리티 검증에 쓴다.
package main

import (
	"fmt"
	"sort"

	"github.com/athens96/amon/windows/internal/config"
	"github.com/athens96/amon/windows/internal/scan"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		fmt.Println("config 로드 실패(기본 경로 사용):", err)
	}
	for _, s := range scan.ScanAll(cfg.Paths) {
		fmt.Printf("== %s ==\n", s.DisplayName)
		fmt.Printf("  TODAY     : %s\n", group(s.Today.Total))
		fmt.Printf("  total     : %s\n", group(s.Usage.Total))
		fmt.Printf("  input     : %s\n", group(s.Usage.Input))
		fmt.Printf("  output    : %s\n", group(s.Usage.Output))
		fmt.Printf("  cacheRead : %s\n", group(s.Usage.CacheRead))
		fmt.Printf("  cacheWrite: %s\n", group(s.Usage.CacheWrite))
		fmt.Printf("  reasoning : %s\n", group(s.Usage.Reasoning))
		if len(s.Models) > 0 {
			type kv struct {
				k string
				v int64
			}
			var models []kv
			for k, v := range s.Models {
				models = append(models, kv{k, v})
			}
			sort.Slice(models, func(i, j int) bool { return models[i].v > models[j].v })
			fmt.Print("  models    : ")
			for i, m := range models {
				if i > 0 {
					fmt.Print(", ")
				}
				if i >= 6 {
					break
				}
				fmt.Printf("%s=%s", m.k, group(m.v))
			}
			fmt.Println()
		}
		if s.CostUSD > 0 {
			fmt.Printf("  cost      : $%.4f\n", s.CostUSD)
		}
		fmt.Printf("  sessions  : %d\n", s.Sessions)
		if !s.LastActivity.IsZero() {
			fmt.Printf("  lastActive: %s\n", s.LastActivity.Format("2006-01-02 15:04:05"))
		}
		if s.Note != "" {
			fmt.Printf("  note      : %s\n", s.Note)
		}
	}
}

// group — 1,234,567 형태.
func group(n int64) string {
	s := fmt.Sprintf("%d", n)
	if len(s) <= 3 {
		return s
	}
	var out []byte
	for i, c := range []byte(s) {
		if i > 0 && (len(s)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, c)
	}
	return string(out)
}
