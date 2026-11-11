// Package config reads and writes the CLI's settings file. It is the same KEY=VALUE file the
// bash version wrote (shell-quoted values), but it is parsed, never executed.
package config

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/jvidal86/isardvdi-cli/internal/validate"
)

// Config is the contents of the config file.
type Config struct {
	URL      string // https://host[:port]
	Username string // the corporate account, to pick it at Microsoft
	SSHUser  string // default SSH user on desktops
}

// ErrNoConfig: init has not been run.
var ErrNoConfig = errors.New("No config found. Run: isardvdi init")

// Dir is the settings folder: $ISARDVDI_CONFIG_DIR, else the user's config folder
// (~/.config/isardvdi-cli, %AppData%\isardvdi-cli).
func Dir() (string, error) {
	if d := os.Getenv("ISARDVDI_CONFIG_DIR"); d != "" {
		return d, nil
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "isardvdi-cli"), nil
}

// File is the settings file inside dir.
func File(dir string) string { return filepath.Join(dir, "config") }

// Load reads dir/config. The URL must be https://host.
func Load(dir string) (*Config, error) {
	f, err := os.Open(File(dir))
	if os.IsNotExist(err) {
		return nil, ErrNoConfig
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	c := &Config{}
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("%s line %d: expected KEY=VALUE", File(dir), n)
		}
		val, err := Unquote(v)
		if err != nil {
			return nil, fmt.Errorf("%s line %d: %v", File(dir), n, err)
		}
		switch k {
		case "URL":
			c.URL = val
		case "USERNAME":
			c.Username = val
		case "SSH_USER":
			c.SSHUser = val
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if c.URL == "" {
		return nil, fmt.Errorf("Config %s missing URL. Run: isardvdi init", File(dir))
	}
	if !validate.URL(c.URL) {
		return nil, fmt.Errorf("Config URL must look like https://host (got: %s). Run: isardvdi init", printable(c.URL))
	}
	return c, nil
}

// Save writes dir/config atomically, private to the user.
func Save(dir string, c *Config) error {
	var b strings.Builder
	for _, kv := range [][2]string{{"URL", c.URL}, {"USERNAME", c.Username}, {"SSH_USER", c.SSHUser}} {
		q, err := Quote(kv[1])
		if err != nil {
			return fmt.Errorf("%s: %v", kv[0], err)
		}
		fmt.Fprintf(&b, "%s=%s\n", kv[0], q)
	}
	return WriteFile(File(dir), []byte(b.String()))
}

// WriteFile writes a private file atomically (temp file in the same folder, then rename), even
// when the old file had looser permissions.
func WriteFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err = tmp.Write(data); err == nil {
		err = tmp.Close()
	} else {
		tmp.Close()
	}
	if err == nil {
		err = os.Rename(name, path)
	}
	if err != nil {
		os.Remove(name)
		return fmt.Errorf("Could not write %s: %v", path, err)
	}
	return nil
}

func printable(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return '?'
		}
		return r
	}, s)
}

// Quote writes a value the way bash's printf %q does, so the bash version can still read it.
func Quote(v string) (string, error) {
	if v == "" {
		return "''", nil
	}
	var b strings.Builder
	for _, r := range v {
		switch {
		case r < 0x20 || r == 0x7f:
			return "", errors.New("control characters are not allowed")
		case r >= '0' && r <= '9', r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z',
			strings.ContainsRune("_@%+=:,./-", r), r > 0x7f && (unicode.IsLetter(r) || unicode.IsDigit(r)):
			b.WriteRune(r)
		default:
			b.WriteByte('\\')
			b.WriteRune(r)
		}
	}
	return b.String(), nil
}

// Unquote reads a shell-quoted value: backslash escapes, 'single' and "double" quotes. Anything
// the shell would run or expand ($, `, ;, |, &, <, >, (, ), $'...') is refused.
func Unquote(s string) (string, error) {
	var b strings.Builder
	rs := []rune(s)
	for i := 0; i < len(rs); i++ {
		switch r := rs[i]; r {
		case '\\':
			i++
			if i >= len(rs) {
				return "", errors.New("dangling backslash")
			}
			b.WriteRune(rs[i])
		case '$':
			// Only bash's $'...' (printf %q in a C locale writes non-ASCII this way).
			if i+1 >= len(rs) || rs[i+1] != '\'' {
				return "", errors.New("shell expansion is not allowed in values")
			}
			j, text, err := ansiC(rs, i+2)
			if err != nil {
				return "", err
			}
			b.WriteString(text)
			i = j
		case '\'':
			j := i + 1
			for j < len(rs) && rs[j] != '\'' {
				j++
			}
			if j >= len(rs) {
				return "", errors.New("unterminated quote")
			}
			b.WriteString(string(rs[i+1 : j]))
			i = j
		case '"':
			j := i + 1
			for ; j < len(rs) && rs[j] != '"'; j++ {
				switch rs[j] {
				case '\\':
					j++
					if j >= len(rs) {
						return "", errors.New("dangling backslash")
					}
					if !strings.ContainsRune("$`\"\\", rs[j]) {
						b.WriteRune('\\')
					}
					b.WriteRune(rs[j])
				case '$', '`':
					return "", errors.New("shell expansion is not allowed in values")
				default:
					b.WriteRune(rs[j])
				}
			}
			if j >= len(rs) {
				return "", errors.New("unterminated quote")
			}
			i = j
		case '`', ';', '|', '&', '<', '>', '(', ')', ' ', '\t', '*', '?', '[', ']', '{', '}', '~', '#', '!':
			return "", fmt.Errorf("unsupported character %q in an unquoted value", r)
		default:
			b.WriteRune(r)
		}
	}
	return b.String(), nil
}

// ansiC reads the inside of $'...' from rs[i:], returning the index of the closing quote. It
// understands \\, \', \", \NNN (octal) and \xHH; the result must be valid text without control
// characters.
func ansiC(rs []rune, i int) (int, string, error) {
	var raw []byte
	for ; i < len(rs); i++ {
		switch r := rs[i]; {
		case r == '\'':
			if !utf8.Valid(raw) || strings.ContainsFunc(string(raw), func(c rune) bool { return c < 0x20 || c == 0x7f }) {
				return 0, "", errors.New("invalid or control characters in a value")
			}
			return i, string(raw), nil
		case r == '\\':
			i++
			if i >= len(rs) {
				return 0, "", errors.New("dangling backslash")
			}
			switch c := rs[i]; {
			case c == '\\' || c == '\'' || c == '"':
				raw = append(raw, byte(c))
			case c >= '0' && c <= '7':
				n, k := 0, 0
				for k < 3 && i < len(rs) && rs[i] >= '0' && rs[i] <= '7' {
					n = n*8 + int(rs[i]-'0')
					i++
					k++
				}
				i--
				if n > 255 {
					return 0, "", errors.New("bad octal escape")
				}
				raw = append(raw, byte(n))
			case c == 'x' && i+2 < len(rs):
				var n int
				if _, err := fmt.Sscanf(string(rs[i+1:i+3]), "%02x", &n); err != nil {
					return 0, "", errors.New("bad hex escape")
				}
				raw = append(raw, byte(n))
				i += 2
			default:
				return 0, "", fmt.Errorf("unsupported escape \\%c", c)
			}
		default:
			raw = append(raw, string(r)...)
		}
	}
	return 0, "", errors.New("unterminated quote")
}
