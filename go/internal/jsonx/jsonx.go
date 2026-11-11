// Package jsonx reads the server's JSON the way jq would: numbers keep their written form,
// and a missing or null field reads as "absent".
package jsonx

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

// Parse decodes one JSON document. Objects are *Object (they keep their keys in the server's
// order, as jq does), arrays are []any, numbers keep their written form (json.Number).
func Parse(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	v, err := parseValue(dec)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("trailing data after the JSON document")
	}
	return v, nil
}

func parseValue(dec *json.Decoder) (any, error) {
	t, err := dec.Token()
	if err != nil {
		return nil, err
	}
	d, ok := t.(json.Delim)
	if !ok {
		return t, nil // string, json.Number, bool or nil
	}
	if d == '{' {
		o := NewObject()
		for dec.More() {
			kt, err := dec.Token()
			if err != nil {
				return nil, err
			}
			v, err := parseValue(dec)
			if err != nil {
				return nil, err
			}
			o.Put(kt.(string), v)
		}
		_, err := dec.Token() // }
		return o, err
	}
	arr := []any{}
	for dec.More() {
		v, err := parseValue(dec)
		if err != nil {
			return nil, err
		}
		arr = append(arr, v)
	}
	_, err = dec.Token() // ]
	return arr, err
}

// String is jq's tostring: strings as they are, null as "null", the rest as JSON.
func String(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case nil:
		return "null"
	case json.Number:
		return t.String()
	}
	b, _ := marshal(v, "")
	return strings.TrimRight(string(b), "\n")
}

// Truthy is jq's: everything but null and false.
func Truthy(v any) bool { return v != nil && v != false }

// Or is jq's `a // b`.
func Or(a, b any) any {
	if Truthy(a) {
		return a
	}
	return b
}

func marshal(v any, indent string) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", indent)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Pretty is `jq .`: two-space indent, no HTML escaping, a final newline. DEL and the C1
// control characters (some terminals obey them, e.g. U+009B is CSI) are written as \u escapes,
// so server data can't reach the terminal through the output.
func Pretty(v any) ([]byte, error) {
	b, err := marshal(v, "  ")
	if err != nil {
		return nil, err
	}
	return escapeControls(b), nil
}

func escapeControls(b []byte) []byte {
	var out bytes.Buffer
	for _, r := range string(b) {
		if r == 0x7f || (r >= 0x80 && r <= 0x9f) {
			fmt.Fprintf(&out, "\\u%04x", r)
		} else {
			out.WriteRune(r)
		}
	}
	return out.Bytes()
}

// Object is a JSON object that keeps its keys in the order they were added (jq's {a, b, c}).
type Object struct {
	keys []string
	vals map[string]any
}

func NewObject() *Object { return &Object{vals: map[string]any{}} }

// Put adds or replaces a key, null included. A replaced key keeps its place.
func (o *Object) Put(k string, v any) {
	if _, ok := o.vals[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.vals[k] = v
}

// Set is Put, but a nil value is skipped (`with_entries(select(.value != null))`).
func (o *Object) Set(k string, v any) {
	if v != nil {
		o.Put(k, v)
	}
}

// Get returns a key's value; a missing key reads as null.
func (o *Object) Get(k string) any { return o.vals[k] }

// Keys returns the keys in order.
func (o *Object) Keys() []string { return o.keys }

func (o *Object) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, k := range o.keys {
		if i > 0 {
			b.WriteByte(',')
		}
		kb, _ := marshal(k, "")
		b.Write(bytes.TrimRight(kb, "\n"))
		b.WriteByte(':')
		vb, err := marshal(o.vals[k], "")
		if err != nil {
			return nil, err
		}
		b.Write(bytes.TrimRight(vb, "\n"))
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}
