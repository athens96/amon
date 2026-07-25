package report

import "testing"

func TestUploadSignatureNormalizesDestinationAndCredentials(t *testing.T) {
	content := "content-digest"
	first := UploadSignature(content, " https://example.com/ ", " user-key ")
	second := UploadSignature(content, "https://example.com/api/v1/ai-agents/report", "user-key")
	if first != second {
		t.Fatal("equivalent destinations and trimmed keys must produce the same signature")
	}
}

func TestUploadSignatureChangesWithKeyServerOrContent(t *testing.T) {
	base := UploadSignature("content-a", "https://one.example", "key-a")
	cases := []struct {
		name      string
		content   string
		serverURL string
		userKey   string
	}{
		{name: "key", content: "content-a", serverURL: "https://one.example", userKey: "key-b"},
		{name: "server", content: "content-a", serverURL: "https://two.example", userKey: "key-a"},
		{name: "content", content: "content-b", serverURL: "https://one.example", userKey: "key-a"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := UploadSignature(tc.content, tc.serverURL, tc.userKey); got == base {
				t.Fatalf("%s change must invalidate upload signature", tc.name)
			}
		})
	}
}
