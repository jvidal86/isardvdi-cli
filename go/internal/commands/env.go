// Package commands holds one file per isardvdi command. A command gets an Env and the
// arguments, and returns an error to print; it never touches the OS directly, so a change here
// is a change on every platform.
package commands

import (
	"fmt"
	"io"
	"os"
	"time"

	"github.com/jvidal86/isardvdi-cli/internal/api"
	"github.com/jvidal86/isardvdi-cli/internal/auth"
	"github.com/jvidal86/isardvdi-cli/internal/config"
	"github.com/jvidal86/isardvdi-cli/internal/fsperm"
	"github.com/jvidal86/isardvdi-cli/internal/secrets"
)

// Env is everything a command needs. Tests fill it with fakes.
type Env struct {
	Out, Err io.Writer
	Dir      string // settings folder
	Getenv   func(string) string
	Now      func() time.Time
	HTTP     *api.Client // set by tests; else built from the config

	cfg    *config.Config
	store  *secrets.Store
	client *api.Client
}

// NewEnv is the real environment.
func NewEnv() (*Env, error) {
	dir, err := config.Dir()
	if err != nil {
		return nil, err
	}
	return &Env{Out: os.Stdout, Err: os.Stderr, Dir: dir, Getenv: os.Getenv, Now: time.Now}, nil
}

// Notef prints a note to the user (stderr).
func (e *Env) Notef(format string, a ...any) { fmt.Fprintf(e.Err, format+"\n", a...) }

// Config loads the settings once, after making the settings folder private.
func (e *Env) Config() (*config.Config, error) {
	if e.cfg != nil {
		return e.cfg, nil
	}
	for _, p := range []string{e.Dir, config.File(e.Dir)} {
		note, err := fsperm.Private(p)
		if err != nil {
			return nil, err
		}
		if note != "" {
			e.Notef("%s", note)
		}
	}
	c, err := config.Load(e.Dir)
	if err != nil {
		return nil, err
	}
	e.cfg = c
	return c, nil
}

// Store is the secret store.
func (e *Env) Store() *secrets.Store {
	if e.store == nil {
		e.store = secrets.New(e.Dir)
		e.store.Warn = func(m string) { e.Notef("%s", m) }
	}
	return e.store
}

// API is the client for the configured server.
func (e *Env) API() (*api.Client, error) {
	if e.HTTP != nil {
		return e.HTTP, nil
	}
	if e.client != nil {
		return e.client, nil
	}
	c, err := e.Config()
	if err != nil {
		return nil, err
	}
	a := &auth.Auth{Store: e.Store(), Getenv: e.Getenv, Now: e.Now}
	e.client = api.New(c.URL, a)
	e.client.Note = func(m string) { e.Notef("%s", m) }
	return e.client, nil
}

// Command is one isardvdi command.
type Command func(e *Env, args []string) error

// Registry maps every command name and alias to its implementation.
var Registry = map[string]Command{
	"list": List, "ls": List,
	"status": Status,
	"get":    Get,
}

// NotPorted lists the commands of the bash version that this build doesn't have yet.
var NotPorted = []string{
	"init", "login", "start", "stop", "rename", "extend", "ssh", "tunnel", "viewer", "vpn",
	"vpn-config", "vpn-reload", "deployments", "deployment", "bastion", "web", "schedule",
	"students", "console", "apikey", "media", "template", "forget", "update",
	// aliases of the above
	"forward", "spice", "vpn-restart", "deps", "dep", "schedules", "sched", "templates",
	"api-key", "self-update", "upgrade",
}
