// Package api talks to the IsardVDI REST API. It knows nothing about the operating system.
package api

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jvidal86/isardvdi-cli/internal/sanitize"
	"github.com/jvidal86/isardvdi-cli/internal/validate"
)

// Kind is where the token comes from. It decides what a rejected token means.
type Kind int

const (
	// Login: a SAML sign-in's token. IsardVDI keeps one login session per user, so another
	// sign-in (the web browser) revokes it: one retry with a fresh sign-in is right.
	Login Kind = iota
	// APIKey has its own pseudo-session: a rejection means the key is bad, never "sign in again".
	APIKey
	// Portal: a token copied from the web browser (PORTAL_JWT).
	Portal
)

// Credentials gives the API its bearer token.
type Credentials interface {
	JWT() (string, error)
	Kind() Kind
	Invalidate() // forget a cached login token that the server rejected
}

// HTTPError is a non-2xx answer, or no answer (Status 0).
type HTTPError struct {
	Method, Path string
	Status       int
	Body         string
}

func (e *HTTPError) Error() string {
	return fmt.Sprintf("HTTP %03d on %s %s: %s", e.Status, e.Method, e.Path, sanitize.Clean(e.Body))
}

// Temporary: worth retrying (no answer, or a server error). Anything else won't get better.
func (e *HTTPError) Temporary() bool { return e.Status == 0 || e.Status >= 500 }

// Client calls one IsardVDI server.
type Client struct {
	BaseURL string
	Creds   Credentials
	HTTP    *http.Client
	Note    func(string) // progress notes for the user; may be nil
}

// NewHTTPClient: 15 s to connect, 120 s in all, and no redirects (a token must never follow a
// redirect to another host; curl doesn't either).
func NewHTTPClient() *http.Client {
	tr := &http.Transport{
		Proxy:               http.ProxyFromEnvironment,
		DialContext:         (&net.Dialer{Timeout: 15 * time.Second}).DialContext,
		TLSHandshakeTimeout: 15 * time.Second,
	}
	// ISARDVDI_CA_FILE: also trust the certificate authorities in this PEM file (a school's
	// proxy, or a test server). The system's own are kept.
	if f := os.Getenv("ISARDVDI_CA_FILE"); f != "" {
		pool, err := x509.SystemCertPool()
		if err != nil || pool == nil {
			pool = x509.NewCertPool()
		}
		if pem, err := os.ReadFile(f); err == nil && pool.AppendCertsFromPEM(pem) {
			tr.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
		}
	}
	return &http.Client{
		Timeout:       120 * time.Second,
		Transport:     tr,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

// New returns a client for baseURL (https://host[:port]).
func New(baseURL string, creds Credentials) *Client {
	return &Client{BaseURL: baseURL, Creds: creds, HTTP: NewHTTPClient()}
}

func (c *Client) note(m string) {
	if c.Note != nil {
		c.Note(m)
	}
}

// Call sends one request and returns the body of a 2xx answer. With a login token it retries
// once after a 401. body may be nil.
func (c *Client) Call(method, path string, body []byte) ([]byte, error) {
	if !validate.APIPath(path) {
		return nil, fmt.Errorf("Invalid API path: %s (must start with /)", sanitize.Clean(path))
	}
	if !strings.HasPrefix(c.BaseURL, "https://") {
		return nil, errors.New("The server URL must be https")
	}
	var status int
	var out []byte
	for attempt := 1; attempt <= 2; attempt++ {
		jwt, err := c.Creds.JWT()
		if err != nil {
			return nil, err
		}
		status, out = c.send(method, path, body, jwt)
		if status == 401 || status == 403 {
			if c.Creds.Kind() == Portal {
				return nil, fmt.Errorf("The portal rejected the browser token (HTTP %d): %s\nCopy a fresh cookie value right before pasting and retry.", status, sanitize.Clean(string(out)))
			}
		}
		if status == 401 && c.Creds.Kind() == APIKey {
			return nil, errors.New("API key rejected (HTTP 401). Create a new one with: isardvdi apikey create --from-browser")
		}
		if status == 401 && attempt == 1 {
			c.note("JWT rejected - refreshing and retrying...")
			c.Creds.Invalidate()
			continue
		}
		break
	}
	if status < 200 || status > 299 {
		return nil, &HTTPError{Method: method, Path: path, Status: status, Body: string(out)}
	}
	return out, nil
}

// send returns the status (0: no answer) and the body, or the reason there was no answer.
func (c *Client) send(method, path string, body []byte, jwt string) (int, []byte) {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, rd)
	if err != nil {
		return 0, []byte("network error (" + err.Error() + ")")
	}
	req.Header.Set("Authorization", "Bearer "+jwt)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return 0, []byte("network error (" + sanitize.Clean(err.Error()) + ")")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return 0, []byte("network error (" + err.Error() + ")")
	}
	return resp.StatusCode, data
}
