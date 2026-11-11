package secrets

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type fakeKeyring struct {
	m        map[string]string
	setErr   error
	getWrong bool
}

func (f *fakeKeyring) Set(s, n, v string) error {
	if f.setErr != nil {
		return f.setErr
	}
	f.m[s+"/"+n] = v
	return nil
}
func (f *fakeKeyring) Get(s, n string) (string, error) {
	if f.getWrong {
		return "something else", nil
	}
	v, ok := f.m[s+"/"+n]
	if !ok {
		return "", ErrNotFound
	}
	return v, nil
}
func (f *fakeKeyring) Delete(s, n string) error { delete(f.m, s+"/"+n); return nil }

func TestFileStore(t *testing.T) {
	s := &Store{Dir: t.TempDir()}
	if _, err := s.Load("token"); err != ErrNotFound {
		t.Fatalf("empty store: %v", err)
	}
	if err := s.Save("token", "abc"); err != nil {
		t.Fatal(err)
	}
	if v, err := s.Load("token"); v != "abc" || err != nil || !s.Exists("token") {
		t.Errorf("%q %v", v, err)
	}
	if fi, _ := os.Stat(filepath.Join(s.Dir, "token")); fi.Mode().Perm()&0o077 != 0 && os.PathSeparator == '/' {
		t.Errorf("mode %v", fi.Mode())
	}
	s.Clear("token")
	if s.Exists("token") {
		t.Error("still there after Clear")
	}
}

func TestKeyringStoreLeavesNoFileAndMarksIt(t *testing.T) {
	kr := &fakeKeyring{m: map[string]string{}}
	s := &Store{Dir: t.TempDir(), Keyring: kr}
	if err := s.Save("apikey", "KEY"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(s.Dir, "apikey")); err == nil {
		t.Error("the secret is also in a file")
	}
	if _, err := os.Stat(filepath.Join(s.Dir, "apikey.in-keyring")); err != nil {
		t.Error("no marker")
	}
	if v, _ := s.Load("apikey"); v != "KEY" || s.Where("apikey") != "the system keyring" {
		t.Error("load/where")
	}
}

// A keyring that holds a secret but can't be read must be an error, never "no key": falling back
// to a sign-in would log the web browser out.
func TestUnreadableKeyringIsNotNotFound(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "apikey.in-keyring"), nil, 0o600)
	s := &Store{Dir: dir} // no keyring running now
	if _, err := s.Load("apikey"); !errors.Is(err, ErrKeyring) {
		t.Errorf("got %v", err)
	}
	if !s.Exists("apikey") {
		t.Error("Exists must still say yes")
	}
}

func TestHalfWorkingKeyringNeverLosesTheSecret(t *testing.T) {
	for name, kr := range map[string]*fakeKeyring{
		"set fails":        {m: map[string]string{}, setErr: errors.New("locked")},
		"reads back wrong": {m: map[string]string{}, getWrong: true},
	} {
		s := &Store{Dir: t.TempDir(), Keyring: kr}
		if err := s.Save("token", "T"); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if v, err := s.Load("token"); v != "T" || err != nil {
			t.Errorf("%s: secret lost (%q %v)", name, v, err)
		}
		if _, err := os.Stat(filepath.Join(s.Dir, "token.in-keyring")); err == nil {
			t.Errorf("%s: a marker without a key", name)
		}
	}
}

func TestMovingFromKeyringToFileClearsTheOldCopy(t *testing.T) {
	kr := &fakeKeyring{m: map[string]string{}}
	s := &Store{Dir: t.TempDir(), Keyring: kr}
	s.Save("token", "one")
	kr.setErr = errors.New("now broken")
	s.Save("token", "two")
	if len(kr.m) != 0 {
		t.Errorf("an older copy stayed in the keyring: %v", kr.m)
	}
	if v, _ := s.Load("token"); v != "two" {
		t.Error(v)
	}
}

func TestMarkerWriteFailureKeepsNothingHalfDone(t *testing.T) {
	dir := t.TempDir()
	kr := &fakeKeyring{m: map[string]string{}}
	s := &Store{Dir: dir, Keyring: kr}
	os.WriteFile(filepath.Join(dir, "token"), []byte("v1"), 0o600)
	os.Mkdir(filepath.Join(dir, "token.in-keyring"), 0o700) // the marker can't be written
	if err := s.Save("token", "v2"); err == nil {
		t.Error("expected an error")
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "token")); string(b) != "v1" {
		t.Errorf("the key file was lost: %q", b)
	}
}

// The real operating-system keyring (Credential Manager on Windows, Secret Service on Linux).
// Opt-in, because it touches the user's keyring: ISARDVDI_TEST_KEYRING=1. It uses its own
// service name, never the real "isardvdi-cli" one.
func TestSystemKeyringRoundTrip(t *testing.T) {
	if os.Getenv("ISARDVDI_TEST_KEYRING") != "1" {
		t.Skip("set ISARDVDI_TEST_KEYRING=1 to test the real system keyring")
	}
	k := systemKeyring{}
	const svc, item = "isardvdi-cli-selftest", "roundtrip"
	t.Cleanup(func() { k.Delete(svc, item) })
	secret := "s3cr3t-with-ünïcode-and-" + string(make([]byte, 0)) + "a/b\\c"
	if err := k.Set(svc, item, secret); err != nil {
		t.Fatal(err)
	}
	if got, err := k.Get(svc, item); err != nil || got != secret {
		t.Fatalf("%q %v", got, err)
	}
	if err := k.Delete(svc, item); err != nil {
		t.Fatal(err)
	}
	if _, err := k.Get(svc, item); err != ErrNotFound {
		t.Errorf("after Delete: %v", err)
	}
	if err := k.Delete(svc, item); err != nil {
		t.Errorf("deleting a missing item must not fail: %v", err)
	}
}
