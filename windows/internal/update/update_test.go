package update

import "testing"

func TestNewerVersion(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"0.1.1", "0.1.0", true},
		{"0.2.0", "0.1.9", true},
		{"1.0.0", "0.9.9", true},
		{"0.1.0", "0.1.0", false},
		{"0.1.0", "0.1.1", false},
		{"0.1", "0.1.0", false},    // 같은 값 — 짧은 표기
		{"0.1.0.1", "0.1.0", true}, // 4필드 빌드 표기
		{"0.10.0", "0.9.0", true},  // 숫자 비교 (문자열 비교였다면 false)
	}
	for _, c := range cases {
		if got := newerVersion(c.a, c.b); got != c.want {
			t.Errorf("newerVersion(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestAPIBase(t *testing.T) {
	for in, want := range map[string]string{
		"https://monitor.example.com":              "https://monitor.example.com/api/v1",
		"https://monitor.example.com/":             "https://monitor.example.com/api/v1",
		"https://monitor.example.com/api/v1":       "https://monitor.example.com/api/v1",
		"https://monitor.example.com/api/v1/extra": "https://monitor.example.com/api/v1",
		"":                                      "",
	} {
		if got := apiBase(in); got != want {
			t.Errorf("apiBase(%q) = %q, want %q", in, got, want)
		}
	}
}
