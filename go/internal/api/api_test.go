package api

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

type creds struct {
	kind        Kind
	tokens      []string // handed out in turn
	n           int
	invalidated int
}

func (c *creds) JWT() (string, error) {
	t := c.tokens[min(c.n, len(c.tokens)-1)]
	c.n++
	return t, nil
}
func (c *creds) Kind() Kind  { return c.kind }
func (c *creds) Invalidate() { c.invalidated++ }

func client(t *testing.T, h http.HandlerFunc, c *creds) (*Client, *httptest.Server) {
	t.Helper()
	srv := httptest.NewTLSServer(h)
	t.Cleanup(srv.Close)
	cl := New(srv.URL, c)
	cl.HTTP = srv.Client()
	cl.HTTP.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return cl, srv
}

func TestSendsBearerAndBody(t *testing.T) {
	var gotAuth, gotType, gotBody string
	cl, _ := client(t, func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotType = r.Header.Get("Authorization"), r.Header.Get("Content-Type")
		b := make([]byte, 100)
		n, _ := r.Body.Read(b)
		gotBody = string(b[:n])
		w.Write([]byte(`{"ok":true}`))
	}, &creds{tokens: []string{"JWT1"}})
	out, err := cl.Call("POST", "/api/v4/x", []byte(`{"a":1}`))
	if err != nil || string(out) != `{"ok":true}` {
		t.Fatalf("%q %v", out, err)
	}
	if gotAuth != "Bearer JWT1" || gotType != "application/json" || gotBody != `{"a":1}` {
		t.Errorf("%q %q %q", gotAuth, gotType, gotBody)
	}
}

func TestRefusesPathsThatWouldSendTheTokenElsewhere(t *testing.T) {
	var hits atomic.Int32
	cl, _ := client(t, func(w http.ResponseWriter, r *http.Request) { hits.Add(1) }, &creds{tokens: []string{"J"}})
	for _, p := range []string{".evil.com/x", "@evil.com/x", "/a b", "/a\nb", "", "x"} {
		if _, err := cl.Call("GET", p, nil); err == nil {
			t.Errorf("accepted path %q", p)
		}
	}
	if hits.Load() != 0 {
		t.Error("a request was sent")
	}
}

func TestOnlyHTTPS(t *testing.T) {
	cl := New("http://127.0.0.1:1", &creds{tokens: []string{"J"}})
	if _, err := cl.Call("GET", "/x", nil); err == nil || !strings.Contains(err.Error(), "https") {
		t.Errorf("%v", err)
	}
}

func TestNeverFollowsRedirects(t *testing.T) {
	var leaked atomic.Int32
	evil := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked.Add(1) }))
	defer evil.Close()
	cl, _ := client(t, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, evil.URL+"/steal", http.StatusFound)
	}, &creds{tokens: []string{"SECRET"}})
	_, err := cl.Call("GET", "/x", nil)
	var he *HTTPError
	if !errors.As(err, &he) || he.Status != 302 {
		t.Errorf("want HTTP 302 error, got %v", err)
	}
	if leaked.Load() != 0 {
		t.Error("the token followed a redirect to another host")
	}
}

func TestLoginTokenRetriesOnceAfter401(t *testing.T) {
	var calls atomic.Int32
	c := &creds{kind: Login, tokens: []string{"OLD", "NEW"}}
	cl, _ := client(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Header.Get("Authorization") == "Bearer OLD" {
			http.Error(w, "revoked", 401)
			return
		}
		w.Write([]byte("fine"))
	}, c)
	var note string
	cl.Note = func(m string) { note = m }
	out, err := cl.Call("GET", "/x", nil)
	if err != nil || string(out) != "fine" || calls.Load() != 2 || c.invalidated != 1 || note == "" {
		t.Errorf("%q %v calls=%d invalidated=%d", out, err, calls.Load(), c.invalidated)
	}
}

func TestLoginTokenGivesUpAfterOneRetry(t *testing.T) {
	var calls atomic.Int32
	c := &creds{kind: Login, tokens: []string{"A"}}
	cl, _ := client(t, func(w http.ResponseWriter, r *http.Request) { calls.Add(1); http.Error(w, "no", 401) }, c)
	if _, err := cl.Call("GET", "/x", nil); err == nil || calls.Load() != 2 {
		t.Errorf("calls=%d err=%v", calls.Load(), err)
	}
}

// An API key or a browser token must never trigger a sign-in (it would log the browser out).
func TestAPIKeyAndPortalTokenAreNotRetried(t *testing.T) {
	for kind, want := range map[Kind]string{APIKey: "API key rejected", Portal: "rejected the browser token"} {
		var calls atomic.Int32
		c := &creds{kind: kind, tokens: []string{"K"}}
		cl, _ := client(t, func(w http.ResponseWriter, r *http.Request) { calls.Add(1); http.Error(w, "no", 401) }, c)
		_, err := cl.Call("GET", "/x", nil)
		if err == nil || !strings.Contains(err.Error(), want) || calls.Load() != 1 || c.invalidated != 0 {
			t.Errorf("kind %d: %v calls=%d invalidated=%d", kind, err, calls.Load(), c.invalidated)
		}
	}
}

func TestPortalTokenRejectedOn403Too(t *testing.T) {
	cl, _ := client(t, func(w http.ResponseWriter, r *http.Request) { http.Error(w, "no", 403) }, &creds{kind: Portal, tokens: []string{"K"}})
	if _, err := cl.Call("GET", "/x", nil); err == nil || !strings.Contains(err.Error(), "browser token") {
		t.Errorf("%v", err)
	}
}

func TestErrorClassification(t *testing.T) {
	for status, temporary := range map[int]bool{404: false, 400: false, 403: false, 500: true, 503: true} {
		cl, _ := client(t, func(w http.ResponseWriter, r *http.Request) { http.Error(w, "body", status) }, &creds{kind: APIKey, tokens: []string{"K"}})
		_, err := cl.Call("GET", "/x", nil)
		var he *HTTPError
		if !errors.As(err, &he) || he.Temporary() != temporary || he.Status != status {
			t.Errorf("%d: %v", status, err)
		}
	}
}

func TestNoAnswerIsTemporary(t *testing.T) {
	cl, srv := client(t, func(w http.ResponseWriter, r *http.Request) {}, &creds{tokens: []string{"K"}})
	srv.Close()
	_, err := cl.Call("GET", "/x", nil)
	var he *HTTPError
	if !errors.As(err, &he) || !he.Temporary() || he.Status != 0 || !strings.Contains(err.Error(), "HTTP 000") {
		t.Errorf("%v", err)
	}
}

func TestErrorBodyIsCleaned(t *testing.T) {
	cl, _ := client(t, func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "bad \x1b]52;c;ZXZpbA==\x07 \u009b31m", 400)
	}, &creds{kind: APIKey, tokens: []string{"K"}})
	_, err := cl.Call("GET", "/x", nil)
	if err == nil || strings.ContainsAny(err.Error(), "\x1b\x07\u009b") {
		t.Errorf("server text reached the terminal raw: %q", err)
	}
}
