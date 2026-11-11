package validate

import "testing"

func TestURL(t *testing.T) {
	for in, want := range map[string]bool{
		"https://elmeuescriptori.gestioeducativa.gencat.cat": true,
		"https://127.0.0.1:8443":                             true,
		"http://elmeuescriptori.gestioeducativa.gencat.cat":  false,
		"https://evil.com/x":                                 false,
		"https://a.com@evil.com":                             false,
		"https://a.com ":                                     false,
		"":                                                   false,
	} {
		if URL(in) != want {
			t.Errorf("URL(%q) = %v", in, !want)
		}
	}
}

func TestIPv4(t *testing.T) {
	for in, want := range map[string]bool{
		"10.2.118.7": true, "1.2.3.4/22; touch /tmp/pwned #": false, "-oProxyCommand=x": false,
		"010.2.0.1": false, "1.2.3.256": false, "::1": false, "": false,
	} {
		if IPv4(in) != want {
			t.Errorf("IPv4(%q) = %v", in, !want)
		}
	}
}

func TestIDs(t *testing.T) {
	if !UUID("0cf16815-bffb-449b-8949-6757e049299a") || UUID("0CF16815-BFFB-449B-8949-6757E049299A") || UUID("x{1..9}") {
		t.Error("UUID")
	}
	if !ID("abc_DEF-123") || ID("a/b") || ID("a.b") || ID("x{1..9}") || ID("") {
		t.Error("ID")
	}
}

func TestAPIPath(t *testing.T) {
	for in, want := range map[string]bool{
		"/api/v4/items/desktops": true, ".evil.com/x": false, "@evil.com/x": false,
		"/a b": false, "/a\nb": false, "": false, "api/x": false,
	} {
		if APIPath(in) != want {
			t.Errorf("APIPath(%q) = %v", in, !want)
		}
	}
}

func TestPort(t *testing.T) {
	for in, want := range map[string]bool{"22": true, "65535": true, "0": false, "65536": false, "022": false, "x": false} {
		if Port(in) != want {
			t.Errorf("Port(%q)", in)
		}
	}
}
