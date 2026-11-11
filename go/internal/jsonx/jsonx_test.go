package jsonx

import (
	"strings"
	"testing"
)

func TestPrettyKeepsNumbersAndEscapesControls(t *testing.T) {
	v, err := Parse([]byte(`{"big":12345678901234567890,"f":1.50,"s":"a\u001bb\u007fc\u009bd<&>"}`))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := Pretty(v)
	out := string(b)
	for _, want := range []string{"12345678901234567890", "1.50", `\u001b`, `\u007f`, `\u009b`, "<&>"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s in %s", want, out)
		}
	}
	if strings.ContainsAny(out, "\x1b\x7f\u009b") {
		t.Errorf("a raw control character survived: %q", out)
	}
}

func TestObjectOrderAndNulls(t *testing.T) {
	o := NewObject()
	o.Set("name", "n")
	o.Set("gone", nil)
	o.Set("ip", false) // false is kept, only null is dropped
	o.Set("a", parse("1"))
	b, _ := Pretty(o)
	if got := strings.Join(strings.Fields(string(b)), ""); got != `{"name":"n","ip":false,"a":1}` {
		t.Errorf("%s", got)
	}
}

func parse(s string) any { v, _ := Parse([]byte(s)); return v }

func TestParseRejectsTrailingData(t *testing.T) {
	if _, err := Parse([]byte(`{} {}`)); err == nil {
		t.Error("trailing data must be an error")
	}
	if _, err := Parse([]byte(`not json`)); err == nil {
		t.Error("not JSON must be an error")
	}
}

func TestOrAndString(t *testing.T) {
	if Or(nil, "-") != "-" || Or(false, "-") != "-" || Or("x", "-") != "x" {
		t.Error("Or")
	}
	if String(nil) != "null" || String(parse("42")) != "42" || String(parse(`[1,2]`)) != "[1,2]" {
		t.Error("String")
	}
}

func TestParseKeepsKeyOrderLikeJq(t *testing.T) {
	v, _ := Parse([]byte(`{"z":1,"a":{"y":[{"q":1,"b":2}],"c":null},"m":3,"z":9}`))
	b, _ := Pretty(v)
	got := strings.Join(strings.Fields(string(b)), "")
	if got != `{"z":9,"a":{"y":[{"q":1,"b":2}],"c":null},"m":3}` {
		t.Errorf("%s", got) // jq: a duplicate key keeps its first place with the last value
	}
}
