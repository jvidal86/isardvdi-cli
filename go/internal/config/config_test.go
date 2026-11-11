package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRoundTripAndShellCompatibility(t *testing.T) {
	dir := t.TempDir()
	in := &Config{URL: "https://portal.example.org", Username: "Ana García <a@b.cat>", SSHUser: "isard"}
	if err := Save(dir, in); err != nil {
		t.Fatal(err)
	}
	out, err := Load(dir)
	if err != nil || *out != *in {
		t.Fatalf("round trip: %+v %v", out, err)
	}
	raw, _ := os.ReadFile(File(dir))
	if strings.Contains(string(raw), `"`) || !strings.Contains(string(raw), `USERNAME=Ana\ García\ \<a@b.cat\>`) {
		t.Errorf("not in printf %%q style (the bash version must still read it): %s", raw)
	}
}

func TestLoadReadsWhatBashWrote(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(File(dir), []byte("URL=https://x.example.org\nUSERNAME=''\nSSH_USER=isard\n"), 0o600)
	c, err := Load(dir)
	if err != nil || c.URL != "https://x.example.org" || c.Username != "" || c.SSHUser != "isard" {
		t.Errorf("%+v %v", c, err)
	}
}

func TestLoadNeverExecutes(t *testing.T) { // the bash version sourced this file as code
	for _, bad := range []string{
		"URL=https://x.org\nUSERNAME=$(touch PWNED)", "URL=https://x.org\nUSERNAME=`touch PWNED`",
		"URL=https://x.org\nUSERNAME=a;touch PWNED", "URL=https://x.org\nUSERNAME=\"$HOME\"",
		"URL=https://x.org\nUSERNAME=$'\\x01'", "URL=https://x.org\nUSERNAME=$'\\n'", "URL=https://x.org\nUSERNAME=a b",
	} {
		dir := t.TempDir()
		os.WriteFile(File(dir), []byte(bad), 0o600)
		if _, err := Load(dir); err == nil {
			t.Errorf("accepted %q", bad)
		}
		if _, err := os.Stat(filepath.Join(dir, "PWNED")); err == nil {
			t.Errorf("ran %q", bad)
		}
	}
}

func TestLoadChecksURL(t *testing.T) {
	for _, u := range []string{"http://x.org", "https://x.org/path", "https://a.com@evil.com", ""} {
		dir := t.TempDir()
		os.WriteFile(File(dir), []byte("URL="+u+"\n"), 0o600)
		if _, err := Load(dir); err == nil {
			t.Errorf("accepted URL %q", u)
		}
	}
	if _, err := Load(t.TempDir()); err != ErrNoConfig {
		t.Errorf("no file: %v", err)
	}
}

func TestSaveRefusesControlCharacters(t *testing.T) {
	if err := Save(t.TempDir(), &Config{URL: "https://x.org", Username: "a\nURL=https://evil.org"}); err == nil {
		t.Error("a newline in a value could add a setting")
	}
}

func TestWriteFileIsAtomicAndPrivate(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "token")
	os.WriteFile(p, []byte("old"), 0o644) // an old file with loose permissions
	if err := WriteFile(p, []byte("new")); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); string(b) != "new" {
		t.Error("content")
	}
	if fi, _ := os.Stat(p); fi.Mode().Perm()&0o077 != 0 && os.PathSeparator == '/' {
		t.Errorf("mode %v: others can read it", fi.Mode())
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "token.*")); len(left) != 0 {
		t.Errorf("temp files left: %v", left)
	}
}

func TestLoadReadsBashCLocaleQuoting(t *testing.T) { // printf %q in a C locale: $'Garc\303\255a'
	dir := t.TempDir()
	os.WriteFile(File(dir), []byte("URL=https://x.org\nUSERNAME=$'Garc\\303\\255a'\nSSH_USER=$'\\x69sard'\n"), 0o600)
	c, err := Load(dir)
	if err != nil || c.Username != "García" || c.SSHUser != "isard" {
		t.Errorf("%+v %v", c, err)
	}
}
