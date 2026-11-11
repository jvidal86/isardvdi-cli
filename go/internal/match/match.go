// Package match finds the one item a user means by a name or an id.
package match

import (
	"fmt"
	"sort"
	"strings"

	"github.com/jvidal86/isardvdi-cli/internal/jsonx"
	"github.com/jvidal86/isardvdi-cli/internal/sanitize"
)

// Candidate is one item of a list that matched.
type Candidate struct{ ID, Label string }

// AmbiguousError lists the items a query matched when it matched more than one.
type AmbiguousError struct {
	Kind, Query string
	Matches     []Candidate
}

func (e *AmbiguousError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "Multiple %ss match \"%s\":\n", e.Kind, sanitize.Clean(e.Query))
	for _, m := range e.Matches {
		fmt.Fprintf(&b, "%s\t%s\n", sanitize.Cell(m.ID), sanitize.Cell(m.Label))
	}
	b.WriteString("Be more specific (try the full name or the id).")
	return b.String()
}

func asciiLower(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'A' && r <= 'Z' {
			return r + 32
		}
		return r
	}, s)
}

// lc is the text of any value, lower-cased (ASCII only); null and false are empty.
func lc(v any) string {
	if v == nil || v == false {
		return ""
	}
	return asciiLower(jsonx.String(v))
}

// ByName returns the id of the one item whose id equals query or whose field (default
// "name") contains it, case-insensitively; an exact match wins over substrings. idOK checks
// the id found, which goes into URLs and messages. Items must be JSON objects.
func ByName(kind string, items []any, query, field string, idOK func(string) bool) (string, error) {
	if field == "" {
		field = "name"
	}
	unique := func(in []*jsonx.Object) []*jsonx.Object {
		seen := map[string]bool{}
		out := []*jsonx.Object{}
		for _, m := range in {
			id, _ := m.Get("id").(string)
			if !seen[id] {
				seen[id] = true
				out = append(out, m)
			}
		}
		sort.SliceStable(out, func(i, j int) bool {
			a, _ := out[i].Get("id").(string)
			b, _ := out[j].Get("id").(string)
			return a < b
		})
		return out
	}
	q := asciiLower(query)
	var exact, partial []*jsonx.Object
	for _, it := range items {
		m, ok := it.(*jsonx.Object)
		if !ok {
			return "", fmt.Errorf("Unexpected answer from the server (not a list of %ss).", kind)
		}
		if id, _ := m.Get("id").(string); id == query || lc(m.Get(field)) == q {
			exact = append(exact, m)
		}
		if strings.Contains(lc(m.Get(field)), q) {
			partial = append(partial, m)
		}
	}
	found := unique(exact)
	if len(found) != 1 {
		found = unique(partial)
	}
	switch len(found) {
	case 0:
		return "", fmt.Errorf("No %s matches \"%s\"", kind, sanitize.Clean(query))
	case 1:
	default:
		e := &AmbiguousError{Kind: kind, Query: query}
		for _, m := range found {
			id, _ := m.Get("id").(string)
			e.Matches = append(e.Matches, Candidate{ID: id, Label: jsonx.String(m.Get(field))})
		}
		return "", e
	}
	id, _ := found[0].Get("id").(string)
	if !idOK(id) {
		return "", fmt.Errorf("The server returned an invalid %s id: %s", kind, sanitize.Clean(id))
	}
	return id, nil
}
