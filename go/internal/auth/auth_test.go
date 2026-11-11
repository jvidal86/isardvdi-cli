package auth

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jvidal86/isardvdi-cli/internal/api"
	"github.com/jvidal86/isardvdi-cli/internal/secrets"
)

var now = time.Unix(1_800_000_000, 0)

func tok(claims string) string {
	b := func(s string) string { return base64.RawURLEncoding.EncodeToString([]byte(s)) }
	return b(`{"alg":"HS256"}`) + "." + b(claims) + ".c2ln"
}

func newAuth(t *testing.T, env map[string]string) *Auth {
	t.Helper()
	return &Auth{Store: &secrets.Store{Dir: t.TempDir()}, Getenv: func(k string) string { return env[k] }, Now: func() time.Time { return now }}
}

func TestExp(t *testing.T) {
	for claims, want := range map[string]struct {
		n  int64
		ok bool
	}{
		`{"exp":1824197512}`:          {1824197512, true},
		`{"exp":1824197512.7}`:        {1824197512, true}, // float -> integer
		`{"exp":"1+1"}`:               {0, false},         // a string is never trusted
		`{"exp":"a[$(touch PWNED)]"}`: {0, false},
		`{"exp":-5}`:                  {0, false},
		`{"exp":1e30}`:                {0, false},
		`{}`:                          {0, false},
		`[1]`:                         {0, false},
	} {
		if n, ok := Exp(tok(claims)); n != want.n || ok != want.ok {
			t.Errorf("Exp(%s) = %d,%v", claims, n, ok)
		}
	}
	if _, ok := Exp("not-a-jwt"); ok {
		t.Error("garbage")
	}
}

func TestPortalJWTWins(t *testing.T) {
	a := newAuth(t, map[string]string{"PORTAL_JWT": "BROWSER"})
	a.Store.Save(APIKeyName, tok(`{"exp":1900000000}`))
	if j, err := a.JWT(); j != "BROWSER" || err != nil || a.Kind() != api.Portal {
		t.Errorf("%q %v", j, err)
	}
}

func TestAPIKey(t *testing.T) {
	a := newAuth(t, nil)
	good := tok(`{"exp":1900000000}`)
	a.Store.Save(APIKeyName, good)
	if j, err := a.JWT(); j != good || err != nil || a.Kind() != api.APIKey {
		t.Errorf("%q %v", j, err)
	}
	a.Store.Save(APIKeyName, tok(`{"exp":1700000000}`))
	if _, err := a.JWT(); err == nil || !strings.Contains(err.Error(), "expired on") {
		t.Errorf("expired key: %v", err)
	}
	a.Store.Save(APIKeyName, tok(`{"exp":"1+1"}`))
	if _, err := a.JWT(); err == nil || !strings.Contains(err.Error(), "not valid (no expiry date)") {
		t.Errorf("bad exp: %v", err)
	}
}

func TestAPIKeyNeverFallsBackToSignIn(t *testing.T) {
	a := newAuth(t, nil)
	called := false
	a.SignIn = func() (string, error) { called = true; return tok(`{"exp":1900000000}`), nil }
	os.WriteFile(filepath.Join(a.Store.Dir, "apikey.in-keyring"), nil, 0o600) // key in an unreadable keyring
	if _, err := a.JWT(); err == nil {
		t.Error("expected an error")
	}
	if called {
		t.Error("signed in: that would log the web browser out")
	}
}

func TestCachedTokenAndRefresh(t *testing.T) {
	a := newAuth(t, nil)
	signIns := 0
	fresh := tok(`{"exp":1900000000}`)
	a.SignIn = func() (string, error) { signIns++; return fresh, nil }
	a.Store.Save(TokenName, tok(`{"exp":1800000200}`)) // 200 s left: under the 5 minute margin
	if j, _ := a.JWT(); j != fresh || signIns != 1 {
		t.Error("a token about to expire must be renewed")
	}
	if j, _ := a.JWT(); j != fresh || signIns != 1 {
		t.Error("the new token must be cached")
	}
	a.Invalidate()
	a.JWT()
	if signIns != 2 {
		t.Error("an invalidated token must be renewed")
	}
}

func TestNoSignInAvailable(t *testing.T) {
	if _, err := newAuth(t, nil).JWT(); err == nil || !strings.Contains(err.Error(), "not available in this build") {
		t.Errorf("%v", err)
	}
}

func TestForceLoginTokenIgnoresAPIKey(t *testing.T) {
	a := newAuth(t, nil)
	a.Store.Save(APIKeyName, tok(`{"exp":1900000000}`))
	a.ForceLoginToken = true
	a.SignIn = func() (string, error) { return "LOGIN", nil }
	if j, _ := a.JWT(); j != "LOGIN" || a.Kind() != api.Login {
		t.Error(j)
	}
}
