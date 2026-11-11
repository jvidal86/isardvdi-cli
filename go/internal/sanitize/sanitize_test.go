package sanitize

import (
	"testing"
	"unicode/utf8"
)

func TestClean(t *testing.T) {
	cases := map[string]string{
		"a\x1b]52;c;ZXZpbA==\x07b": "a]52;c;ZXZpbA==b", // OSC 52 clipboard
		"a\x1b[2Jb\u009b31mc":      "a[2Jb31mc",        // ESC and UTF-8 C1 (CSI)
		"Vergés García":            "Vergés García",    // accents survive
		"a\tb\nc":                  "a\tb\nc",          // tab and newline stay
		"a\rb\x7fc":                "abc",              // CR and DEL go
	}
	for in, want := range cases {
		if got := Clean(in); got != want {
			t.Errorf("Clean(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCleanBrokenUTF8LeavesNoControl(t *testing.T) {
	got := Clean("a\xc2\xc2\x9b\x9bb") // C2 C2 9B 9B: a C1 hiding behind a stray lead byte
	if !utf8.ValidString(got) {
		t.Errorf("invalid UTF-8 left in the output: %q", got)
	}
	for _, r := range got {
		if r >= 0x80 && r <= 0x9f {
			t.Errorf("a C1 control character survived: %q", got)
		}
	}
}

func TestCell(t *testing.T) {
	if got := Cell("x\x1b[2Jy\tz\n"); got != "x?[2Jy?z?" {
		t.Errorf("Cell = %q", got)
	}
}
