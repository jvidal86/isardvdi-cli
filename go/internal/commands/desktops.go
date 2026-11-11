package commands

import (
	"errors"
	"fmt"
	"text/tabwriter"

	"github.com/jvidal86/isardvdi-cli/internal/jsonx"
	"github.com/jvidal86/isardvdi-cli/internal/match"
	"github.com/jvidal86/isardvdi-cli/internal/sanitize"
	"github.com/jvidal86/isardvdi-cli/internal/validate"
)

// desktops fetches your desktops (the list endpoint matches the web UI and reports status and
// ip reliably during transitions).
func (e *Env) desktops() ([]any, error) {
	c, err := e.API()
	if err != nil {
		return nil, err
	}
	body, err := c.Call("GET", "/api/v4/items/desktops", nil)
	if err != nil {
		return nil, err
	}
	v, err := jsonx.Parse(body)
	obj, ok := v.(*jsonx.Object)
	if err != nil || !ok {
		return nil, errors.New("Unexpected answer from the server (not a desktop list).")
	}
	list, ok := obj.Get("desktops").([]any)
	if !ok {
		return nil, errors.New("Unexpected answer from the server (no desktop list).")
	}
	return list, nil
}

// List prints your desktops: name, state, IP, id.
func List(e *Env, args []string) error {
	list, err := e.desktops()
	if err != nil {
		return err
	}
	tw := tabwriter.NewWriter(e.Out, 0, 8, 2, ' ', 0)
	fmt.Fprintln(tw, "NAME\tSTATE\tIP\tID")
	for _, it := range list {
		m, ok := it.(*jsonx.Object)
		if !ok {
			return errors.New("Unexpected answer from the server (not a list of desktops).")
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n",
			sanitize.Cell(jsonx.String(m.Get("name"))), sanitize.Cell(jsonx.String(m.Get("status"))),
			sanitize.Cell(jsonx.String(jsonx.Or(m.Get("ip"), "-"))), sanitize.Cell(jsonx.String(m.Get("id"))))
	}
	return tw.Flush()
}

// Status prints one desktop's details as JSON.
func Status(e *Env, args []string) error {
	if len(args) == 2 {
		return errors.New("status <deployment> <student> is not in this build yet.")
	}
	if len(args) != 1 {
		return errors.New("Usage: isardvdi status <desktop> | <deployment> <student>")
	}
	list, err := e.desktops()
	if err != nil {
		return err
	}
	var id string
	own := false
	if validate.UUID(args[0]) {
		id = args[0]
		for _, it := range list {
			if m, ok := it.(*jsonx.Object); ok && m.Get("id") == id {
				own = true
			}
		}
	} else if id, err = match.ByName("desktop", list, args[0], "name", validate.UUID); err != nil {
		return err
	} else {
		own = true
	}
	if !validate.UUID(id) {
		return fmt.Errorf("Invalid desktop id: %s", sanitize.Clean(id))
	}
	c, err := e.API()
	if err != nil {
		return err
	}
	body, err := c.Call("GET", "/api/v4/item/desktop/"+id+"/get-info", nil)
	if err != nil {
		return err
	}
	dv, err := jsonx.Parse(body)
	d, ok := dv.(*jsonx.Object)
	if err != nil || !ok {
		return errors.New("Unexpected answer from the server (not a desktop).")
	}
	// State and IP from the list (get-info reports no IP for a student's desktop).
	n := d
	if own {
		for _, it := range list {
			if m, ok := it.(*jsonx.Object); ok && m.Get("id") == id {
				n = m
			}
		}
	}
	out := jsonx.NewObject()
	out.Set("name", d.Get("name"))
	if jsonx.Truthy(n.Get("user_name")) {
		out.Set("student", n.Get("user_name"))
		out.Set("group", n.Get("group_name"))
	}
	out.Set("status", jsonx.Or(n.Get("status"), d.Get("status")))
	out.Set("ip", jsonx.Or(n.Get("ip"), d.Get("ip")))
	out.Set("interfaces", d.Get("interfaces"))
	b, err := jsonx.Pretty(out)
	if err != nil {
		return err
	}
	_, err = e.Out.Write(b)
	return err
}
