package match

import (
	"errors"
	"strings"
	"testing"

	"github.com/jvidal86/isardvdi-cli/internal/jsonx"
	"github.com/jvidal86/isardvdi-cli/internal/validate"
)

func items(t *testing.T, js string) []any {
	t.Helper()
	v, err := jsonx.Parse([]byte(js))
	if err != nil {
		t.Fatal(err)
	}
	return v.([]any)
}

const (
	a = "0cf16815-bffb-449b-8949-6757e049299a"
	b = "1cf16815-bffb-449b-8949-6757e049299a"
)

func TestByName(t *testing.T) {
	list := items(t, `[{"id":"`+a+`","name":"Linux Lab"},{"id":"`+b+`","name":"Linux Lab 2"}]`)
	got, err := ByName("desktop", list, "linux lab", "name", validate.UUID)
	if err != nil || got != a {
		t.Errorf("exact match must win over substrings: %q %v", got, err)
	}
	if got, err = ByName("desktop", list, b, "name", validate.UUID); err != nil || got != b {
		t.Errorf("by id: %q %v", got, err)
	}
	if got, err = ByName("desktop", list, "lab 2", "name", validate.UUID); err != nil || got != b {
		t.Errorf("by substring: %q %v", got, err)
	}
}

func TestByNameAmbiguousAndMissing(t *testing.T) {
	list := items(t, `[{"id":"`+b+`","name":"Lab B"},{"id":"`+a+`","name":"Lab A"}]`)
	_, err := ByName("desktop", list, "lab", "name", validate.UUID)
	var amb *AmbiguousError
	if !errors.As(err, &amb) || len(amb.Matches) != 2 || amb.Matches[0].ID != a {
		t.Fatalf("want an ambiguity error sorted by id, got %v", err)
	}
	if !strings.Contains(err.Error(), "Be more specific") {
		t.Error(err)
	}
	if _, err = ByName("desktop", list, "nothing", "name", validate.UUID); err == nil || !strings.Contains(err.Error(), "No desktop matches") {
		t.Error(err)
	}
}

func TestByNameRejectsBadID(t *testing.T) { // match_one rejects a non-UUID id
	list := items(t, `[{"id":"x{1..9}","name":"Foo"}]`)
	if _, err := ByName("desktop", list, "foo", "name", validate.UUID); err == nil {
		t.Error("a non-UUID id must be refused")
	}
}

func TestByNameSurvivesNonStrings(t *testing.T) { // match_one survives non-string names
	list := items(t, `[{"id":"`+a+`","name":42},{"id":"`+b+`","name":null}]`)
	if got, err := ByName("desktop", list, "42", "name", validate.UUID); err != nil || got != a {
		t.Errorf("%q %v", got, err)
	}
	if _, err := ByName("x", []any{"not an object"}, "q", "name", validate.UUID); err == nil {
		t.Error("a list of non-objects must be an error, not a panic")
	}
}

func TestAmbiguityListIsCleaned(t *testing.T) {
	list := items(t, `[{"id":"`+a+`","name":"A\u001b[2Jx"},{"id":"`+b+`","name":"A2"}]`)
	_, err := ByName("desktop", list, "a", "name", validate.UUID)
	if err == nil || strings.Contains(err.Error(), "\x1b") {
		t.Errorf("server names must not carry an escape to the terminal: %q", err)
	}
}
