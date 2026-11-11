package commands

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jvidal86/isardvdi-cli/internal/api"
)

type staticCreds struct{}

func (staticCreds) JWT() (string, error) { return "J", nil }
func (staticCreds) Kind() api.Kind       { return api.APIKey }
func (staticCreds) Invalidate()          {}

const (
	idA = "0cf16815-bffb-449b-8949-6757e049299a"
	idB = "1cf16815-bffb-449b-8949-6757e049299a"
	idC = "2cf16815-bffb-449b-8949-6757e049299a"
)

// env returns an Env wired to a fake portal serving routes (path -> JSON), plus the buffers.
func env(t *testing.T, routes map[string]string) (*Env, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if body, ok := routes[r.URL.Path]; ok {
			w.Write([]byte(body))
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(srv.Close)
	cl := api.New(srv.URL, staticCreds{})
	cl.HTTP = srv.Client()
	var out, errb bytes.Buffer
	return &Env{Out: &out, Err: &errb, Dir: t.TempDir(), Getenv: func(string) string { return "" },
		Now: time.Now, HTTP: cl}, &out, &errb
}

const list = `{"desktops":[
 {"id":"` + idA + `","name":"Linux Lab","status":"Started","ip":"10.2.0.5"},
 {"id":"` + idB + `","name":"Windows Lab","status":"Stopped","ip":null},
 {"id":"` + idC + `","name":"Evil\u001b[2J\tName","status":"Stopped"}]}`

func TestList(t *testing.T) {
	e, out, _ := env(t, map[string]string{"/api/v4/items/desktops": list})
	if err := List(e, nil); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if len(lines) != 4 {
		t.Fatalf("%d lines:\n%s", len(lines), out)
	}
	if f := strings.Fields(lines[0]); strings.Join(f, " ") != "NAME STATE IP ID" {
		t.Errorf("header %q", lines[0])
	}
	if !strings.Contains(lines[1], "10.2.0.5") || !strings.Contains(lines[2], " - ") {
		t.Errorf("ip column:\n%s", out)
	}
	if strings.ContainsAny(out.String(), "\x1b") || !strings.Contains(lines[3], "Evil?[2J?Name") {
		t.Errorf("control characters in a name must show as ?:\n%q", lines[3])
	}
	if strings.Index(lines[1], "Started") != strings.Index(lines[0], "STATE") {
		t.Errorf("columns not aligned:\n%s", out)
	}
}

func TestListUnexpectedAnswer(t *testing.T) {
	for _, body := range []string{`{}`, `[]`, `not json`, `{"desktops":{}}`, `{"desktops":[1]}`} {
		e, _, _ := env(t, map[string]string{"/api/v4/items/desktops": body})
		if err := List(e, nil); err == nil || !strings.Contains(err.Error(), "Unexpected answer") {
			t.Errorf("%s: %v", body, err)
		}
	}
}

const info = `{"id":"` + idA + `","name":"Linux Lab","status":"Stopped","ip":null,"interfaces":{"wireguard":{"ip":"10.2.0.5"}},"secret_field":"x"}`

func TestStatusByNameMergesListState(t *testing.T) {
	e, out, _ := env(t, map[string]string{"/api/v4/items/desktops": list, "/api/v4/item/desktop/" + idA + "/get-info": info})
	if err := Status(e, []string{"linux"}); err != nil {
		t.Fatal(err)
	}
	want := `{
  "name": "Linux Lab",
  "status": "Started",
  "ip": "10.2.0.5",
  "interfaces": {
    "wireguard": {
      "ip": "10.2.0.5"
    }
  }
}
`
	if out.String() != want {
		t.Errorf("got:\n%s\nwant:\n%s", out, want)
	}
}

func TestStatusByUUIDNotInYourList(t *testing.T) { // a desktop that isn't yours: get-info only
	e, out, _ := env(t, map[string]string{"/api/v4/items/desktops": `{"desktops":[]}`, "/api/v4/item/desktop/" + idA + "/get-info": info})
	if err := Status(e, []string{idA}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), `"status": "Stopped"`) || strings.Contains(out.String(), "ip") && strings.Contains(out.String(), `"ip": null`) {
		t.Errorf("%s", out)
	}
}

func TestStatusStudentFieldsFromTheList(t *testing.T) {
	l := `{"desktops":[{"id":"` + idA + `","name":"L","status":"Started","user_name":"Ana","group_name":"ASIX1"}]}`
	e, out, _ := env(t, map[string]string{"/api/v4/items/desktops": l, "/api/v4/item/desktop/" + idA + "/get-info": `{"name":"L"}`})
	if err := Status(e, []string{idA}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), `"student": "Ana"`) || !strings.Contains(out.String(), `"group": "ASIX1"`) {
		t.Errorf("%s", out)
	}
}

func TestStatusErrors(t *testing.T) {
	routes := map[string]string{"/api/v4/items/desktops": list}
	for _, tc := range []struct {
		args []string
		want string
	}{
		{nil, "Usage"}, {[]string{"a", "b", "c"}, "Usage"}, {[]string{"nothing"}, "No desktop matches"},
		{[]string{"lab"}, "Multiple desktops"}, {[]string{"a", "b"}, "not in this build"},
	} {
		e, _, _ := env(t, routes)
		if err := Status(e, tc.args); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%v: %v", tc.args, err)
		}
	}
}

func TestStatusRefusesAServerIDThatIsNotAUUID(t *testing.T) {
	l := `{"desktops":[{"id":"../../etc","name":"Foo"}]}`
	e, _, _ := env(t, map[string]string{"/api/v4/items/desktops": l})
	if err := Status(e, []string{"foo"}); err == nil {
		t.Error("an id from the server went into a URL unchecked")
	}
}

func TestGet(t *testing.T) {
	e, out, _ := env(t, map[string]string{"/api/v4/x": `{"b":1,"a":"\u001b"}`, "/plain": "hi \x1b[2J there"})
	if err := Get(e, []string{"/api/v4/x"}); err != nil || out.String() != "{\n  \"b\": 1,\n  \"a\": \"\\u001b\"\n}\n" {
		t.Errorf("%q %v", out, err)
	}
	out.Reset()
	if err := Get(e, []string{"/plain"}); err != nil || out.String() != "hi [2J there\n" {
		t.Errorf("non-JSON must be cleaned: %q %v", out, err)
	}
	if err := Get(e, nil); err == nil {
		t.Error("usage")
	}
	if err := Get(e, []string{"@evil.com/x"}); err == nil {
		t.Error("bad path")
	}
}
