package commands

import (
	"errors"
	"fmt"

	"github.com/jvidal86/isardvdi-cli/internal/jsonx"
	"github.com/jvidal86/isardvdi-cli/internal/sanitize"
)

// Get prints the answer to GET <api path>: JSON re-indented, anything else cleaned.
func Get(e *Env, args []string) error {
	if len(args) != 1 {
		return errors.New("Usage: isardvdi get </api/path>")
	}
	c, err := e.API()
	if err != nil {
		return err
	}
	body, err := c.Call("GET", args[0], nil)
	if err != nil {
		return err
	}
	if v, err := jsonx.Parse(body); err == nil {
		b, err := jsonx.Pretty(v)
		if err != nil {
			return err
		}
		_, err = e.Out.Write(b)
		return err
	}
	_, err = fmt.Fprintln(e.Out, sanitize.Clean(string(body)))
	return err
}
