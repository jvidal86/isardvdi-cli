// Package sanitize cleans server data on its way to the terminal: escape sequences in a
// desktop name could rewrite the screen or set the clipboard.
package sanitize

import "strings"

func isControl(r rune) bool {
	return r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f)
}

// Clean removes control characters, keeping tab and newline (the bash version's sanitize).
func Clean(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '\t' || r == '\n' {
			return r
		}
		if isControl(r) {
			return -1
		}
		return r
	}, s)
}

// Cell replaces every control character, tab and newline included, with "?": a table cell
// must stay on one line.
func Cell(s string) string {
	return strings.Map(func(r rune) rune {
		if isControl(r) {
			return '?'
		}
		return r
	}, s)
}
