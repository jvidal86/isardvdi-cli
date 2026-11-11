// isardvdi: command-line control of IsardVDI virtual desktops. One program for Linux and Windows.
package main

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"sort"
	"strings"

	"github.com/jvidal86/isardvdi-cli/internal/api"
	"github.com/jvidal86/isardvdi-cli/internal/commands"
	"github.com/jvidal86/isardvdi-cli/internal/sanitize"
)

// Set at build time: -ldflags "-X main.version=1.2.3 -X main.commit=abc1234".
var (
	version = "dev"
	commit  = "unknown"
)

const exitTemporary = 75 // EX_TEMPFAIL: worth retrying (no answer, or a server error)

func main() { os.Exit(run(os.Args[1:])) }

func run(args []string) int {
	if len(args) == 0 {
		args = []string{"help"}
	}
	name, rest := args[0], args[1:]
	switch name {
	case "version", "--version", "-V":
		fmt.Printf("isardvdi %s (%s, %s/%s)\n", version, commit, runtime.GOOS, runtime.GOARCH)
		return 0
	case "help", "-h", "--help":
		help()
		return 0
	}
	env, err := commands.NewEnv()
	if err != nil {
		return fail(err)
	}
	cmd, ok := commands.Registry[name]
	if !ok {
		for _, n := range commands.NotPorted {
			if n == name {
				fmt.Fprintf(os.Stderr, "isardvdi %s is not in this build yet (it is in the bash version).\n", sanitize.Clean(name))
				return 2
			}
		}
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", sanitize.Clean(name))
		help()
		return 1
	}
	if err := cmd(env, rest); err != nil {
		return fail(err)
	}
	return 0
}

func fail(err error) int {
	fmt.Fprintln(os.Stderr, err)
	var he *api.HTTPError
	if errors.As(err, &he) && he.Temporary() {
		return exitTemporary
	}
	return 1
}

func help() {
	var have []string
	for n := range commands.Registry {
		have = append(have, n)
	}
	sort.Strings(have)
	fmt.Printf(`isardvdi - command-line control of IsardVDI virtual desktops (Go build)

USAGE
    isardvdi <command> [arguments]

AVAILABLE IN THIS BUILD
    list                  Your desktops: name, state, IP, id.
    status <desktop>      One desktop's details as JSON.
    get </api/path>       GET an API path and print the answer.
    version               This program's version.

NOT YET (still in the bash version)
    %s

Settings: %s
`, strings.Join(commands.NotPorted, ", "), "ISARDVDI_CONFIG_DIR, else the user's config folder + /isardvdi-cli")
}
