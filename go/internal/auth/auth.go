// Package auth decides which token the API gets: the browser's (PORTAL_JWT), the API key, or a
// cached login token. It never signs in when an API key or a browser token is in use: a SAML
// sign-in would log the web browser out.
package auth

import (
	"encoding/base64"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/jvidal86/isardvdi-cli/internal/api"
	"github.com/jvidal86/isardvdi-cli/internal/jsonx"
	"github.com/jvidal86/isardvdi-cli/internal/secrets"
)

// Names of the stored secrets.
const (
	APIKeyName = "apikey"
	TokenName  = "token"
)

// Auth implements api.Credentials.
type Auth struct {
	Store  *secrets.Store
	Getenv func(string) string
	Now    func() time.Time
	// SignIn does a SAML sign-in and returns the JWT. nil: not available in this build.
	SignIn func() (string, error)
	// ForceLoginToken ignores the API key (creating a key needs a login token).
	ForceLoginToken bool
}

func (a *Auth) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

func (a *Auth) portalJWT() string {
	if a.Getenv == nil {
		return ""
	}
	return a.Getenv("PORTAL_JWT")
}

func (a *Auth) usingAPIKey() bool {
	return !a.ForceLoginToken && a.portalJWT() == "" && a.Store.Exists(APIKeyName)
}

// Kind says where the token comes from.
func (a *Auth) Kind() api.Kind {
	switch {
	case a.portalJWT() != "":
		return api.Portal
	case a.usingAPIKey():
		return api.APIKey
	}
	return api.Login
}

// Invalidate forgets the cached login token.
func (a *Auth) Invalidate() { a.Store.Clear(TokenName) }

// JWT returns the token to send.
func (a *Auth) JWT() (string, error) {
	if p := a.portalJWT(); p != "" {
		return p, nil
	}
	if a.usingAPIKey() {
		jwt, err := a.Store.Load(APIKeyName)
		if err != nil {
			return "", errors.New("The API key is in the system keyring, which can't be read now (locked, or no\ndesktop session, e.g. over SSH). Unlock the keyring, or run this from your desktop session.")
		}
		exp, ok := Exp(jwt)
		if !ok {
			return "", errors.New("The stored API key is not valid (no expiry date). Open the portal in\nyour browser and run: isardvdi apikey create --from-browser")
		}
		if exp <= a.now().Unix() {
			return "", fmt.Errorf("API key expired on %s. Open the portal in your browser, then run:\n    isardvdi apikey create --from-browser\n(or 'isardvdi apikey revoke' to go back to SAML sign-ins)", FormatEpoch(exp))
		}
		return jwt, nil
	}
	// A cached login token is reused until 5 minutes before it expires.
	if jwt, err := a.Store.Load(TokenName); err == nil {
		if exp, ok := Exp(jwt); ok && exp > a.now().Unix()+300 {
			return jwt, nil
		}
	}
	if a.SignIn == nil {
		return "", errors.New("Sign-in is not available in this build yet. Use an API key (isardvdi apikey create) or set PORTAL_JWT.")
	}
	jwt, err := a.SignIn()
	if err != nil {
		return "", err
	}
	if err := a.Store.Save(TokenName, jwt); err != nil {
		return "", err
	}
	return jwt, nil
}

// Payload decodes the claims of a JWT (the signature is not checked: only the server can).
func Payload(token string) (*jsonx.Object, bool) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return nil, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return nil, false
	}
	v, err := jsonx.Parse(raw)
	m, ok := v.(*jsonx.Object)
	return m, err == nil && ok
}

// Exp is the "exp" claim as whole epoch seconds.
func Exp(token string) (int64, bool) {
	p, ok := Payload(token)
	if !ok {
		return 0, false
	}
	n, ok := p.Get("exp").(interface{ Float64() (float64, error) })
	if !ok {
		return 0, false
	}
	f, err := n.Float64()
	if err != nil || f < 0 || f > 999999999999 {
		return 0, false
	}
	return int64(math.Floor(f)), true
}

// FormatEpoch is "2026-11-11 15:04" in local time.
func FormatEpoch(sec int64) string { return time.Unix(sec, 0).Format("2006-01-02 15:04") }
