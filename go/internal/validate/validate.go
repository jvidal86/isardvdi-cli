// Package validate holds the checks every value from the server or the user passes before it
// goes into a URL, a command line or the terminal.
package validate

import (
	"net/netip"
	"regexp"
	"strconv"
)

var (
	urlRe  = regexp.MustCompile(`^https://[A-Za-z0-9.-]+(:[0-9]+)?$`)
	uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	idRe   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	pathRe = regexp.MustCompile(`^/[^\x00-\x20\x7f]*$`)
)

// URL: https://host[:port] and nothing else. Tokens are only ever sent over HTTPS.
func URL(s string) bool { return urlRe.MatchString(s) }

// UUID: the id of a desktop, deployment or student desktop.
func UUID(s string) bool { return uuidRe.MatchString(s) }

// ID: a server id that may go into a URL (no / . { } [ ]).
func ID(s string) bool { return idRe.MatchString(s) }

// IDPattern is what Match uses to check an id: the default rule or the UUID one.
func IDPattern(uuid bool) func(string) bool {
	if uuid {
		return UUID
	}
	return ID
}

// APIPath: a path for the API. "$URL$path" with ".evil.com/x" or "@evil.com/x" would send the
// token elsewhere, so it must start with / and hold no space or control character.
func APIPath(s string) bool { return pathRe.MatchString(s) }

// IPv4 accepts only the canonical dotted form (no leading zeros, no hex).
func IPv4(s string) bool {
	a, err := netip.ParseAddr(s)
	return err == nil && a.Is4() && a.String() == s
}

// Port: 1-65535.
func Port(s string) bool {
	n, err := strconv.Atoi(s)
	return err == nil && n >= 1 && n <= 65535 && strconv.Itoa(n) == s
}
