package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const version = "0.1.0"

// The terminal's way in.
//
// Four operations reach this database and this is one of the two front doors
// onto them. It holds no opinions the node does not hold: it names ledgers,
// puts questions to snapshots, and prints what comes back — including, above
// all, the repair on anything refused.

// usageError is a mistake in the command line rather than a refusal from the
// node. Same shape, so it prints the same way, and its repair is the usage.
type usageError struct{ *Refusal }

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	code := run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	os.Exit(code)
}

func run(ctx context.Context, args []string, out, errOut io.Writer) int {
	if len(args) == 0 {
		writeUsage(out)
		return 2
	}

	// Read off the raw arguments rather than a parsed flag, because this has to
	// hold for the refusals that happen before any parsing succeeds. `--json`
	// promising machine-readable output only once the command line was already
	// right would be a promise that breaks exactly when a script needs it.
	asJSON := slices.Contains(args, "--json") || slices.Contains(args, "-json")

	command, rest, err := hoistGlobals(args)
	if err != nil {
		if asJSON {
			RenderRefusalJSON(errOut, unwrapUsage(err))
		} else {
			RenderRefusal(errOut, unwrapUsage(err))
		}
		return 2
	}

	switch command {
	case "login":
		asJSON, err = cmdLogin(ctx, rest, out, errOut)
	case "logout":
		asJSON, err = cmdLogout(rest, out)
	case "whoami":
		asJSON, err = cmdWhoami(ctx, rest, out)
	case "ledger":
		asJSON, err = cmdLedger(ctx, rest, out)
	case "run":
		asJSON, err = cmdRun(ctx, rest, out)
	case "watch":
		asJSON, err = cmdWatch(ctx, rest, out, errOut)
	case "config":
		asJSON, err = cmdConfig(rest, out)
	case "version", "--version", "-v":
		fmt.Fprintf(out, "blazie %s\n", version)
		return 0
	case "help", "--help", "-h":
		writeUsage(out)
		return 0
	default:
		err = &usageError{&Refusal{
			Problem: "unknown_command",
			Repair: fmt.Sprintf("There is no `blazie %s`. Run `blazie help` for the ones "+
				"there are.", command),
		}}
	}

	if err == nil {
		return 0
	}

	// A cancelled context is somebody pressing Ctrl-C, which is not a failure.
	if errors.Is(err, context.Canceled) {
		return 0
	}

	if asJSON {
		RenderRefusalJSON(errOut, unwrapUsage(err))
	} else {
		RenderRefusal(errOut, unwrapUsage(err))
	}

	if _, ok := err.(*usageError); ok {
		return 2
	}
	return 1
}

// hoistGlobals lets `--url` and `--json` come before the command as well as
// after it.
//
// `blazie --url http://node whoami` and `blazie whoami --url http://node` are
// the same intent, and a CLI that takes only one of them makes somebody read
// the usage to find out which. The flags that mean the same thing everywhere
// are moved onto the command's own arguments; anything else in front of a
// command is a mistake, and gets a repair saying where it belongs.
func hoistGlobals(args []string) (command string, rest []string, err error) {
	var hoisted []string

	for len(args) > 0 {
		arg := args[0]
		if len(arg) < 2 || arg[0] != '-' {
			break
		}

		name, _, hasValue := strings.Cut(strings.TrimLeft(arg, "-"), "=")

		switch name {
		case "help", "h", "version", "v":
			// Not a global flag but a command spelled like one, which is what
			// somebody reaching for `--version` means.
			return arg, nil, nil

		case "json":
			hoisted, args = append(hoisted, arg), args[1:]

		case "url":
			if hasValue || len(args) == 1 {
				hoisted, args = append(hoisted, arg), args[1:]
				continue
			}
			hoisted, args = append(hoisted, arg, args[1]), args[2:]

		default:
			return "", nil, &usageError{&Refusal{
				Problem: "flag_before_command",
				Repair: fmt.Sprintf("%s is a flag on a command rather than on blazie itself — "+
					"put it after the command, as in `blazie ask <ledger> %s`. Only --url and "+
					"--json may come first.", arg, arg),
			}}
		}
	}

	if len(args) == 0 {
		return "", nil, &usageError{&Refusal{
			Problem: "no_command",
			Repair:  "Name an operation. Run `blazie help` for the ones there are.",
		}}
	}

	return args[0], append(args[1:], hoisted...), nil
}

func unwrapUsage(err error) error {
	if u, ok := err.(*usageError); ok {
		return u.Refusal
	}
	return err
}

// ── the shared flags ────────────────────────────────────────────────────────

type common struct {
	set    *flag.FlagSet
	url    string
	asJSON bool
}

// newFlags registers the two flags every command has. `--json` everywhere is a
// rule rather than a convenience: anything a person can read here, a script has
// to be able to read too, without parsing a table.
func newFlags(name string) *common {
	set := flag.NewFlagSet(name, flag.ContinueOnError)
	set.SetOutput(io.Discard)

	c := &common{set: set}
	set.StringVar(&c.url, "url", "", "the node to talk to (overrides BLAZIE_URL and the config)")
	set.BoolVar(&c.asJSON, "json", false, "print what the node said, unshaped")

	return c
}

func (c *common) parse(args []string) error {
	if err := c.set.Parse(permute(c.set, args)); err != nil {
		return &usageError{&Refusal{
			Problem: "bad_flags",
			Repair:  fmt.Sprintf("%v. Run `blazie help`.", err),
		}}
	}
	return nil
}

// permute moves flags in front of the positional arguments.
//
// Go's flag package stops at the first thing that is not a flag, so
// `blazie ask tenant-7 --attribute height` would otherwise reach the node as a
// request to open three ledgers, one of them called "--attribute". The node
// refuses that correctly and with a repair, which is the system working — and
// is still a terrible thing to hand somebody who typed the obvious command.
//
// Whether a flag swallows the next argument depends on whether it is boolean,
// which the FlagSet knows. An unrecognised flag is left where it is so the
// parser produces its own error about it rather than this guessing.
func permute(set *flag.FlagSet, args []string) []string {
	flags := make([]string, 0, len(args))
	positional := make([]string, 0, len(args))

	for i := 0; i < len(args); i++ {
		arg := args[i]

		// Everything after a bare `--` is positional by convention, which is
		// how an id that begins with a dash gets written.
		if arg == "--" {
			positional = append(positional, args[i+1:]...)
			break
		}

		if len(arg) < 2 || arg[0] != '-' {
			positional = append(positional, arg)
			continue
		}

		name := strings.TrimLeft(arg, "-")
		name, _, hasValue := strings.Cut(name, "=")

		flags = append(flags, arg)

		found := set.Lookup(name)
		if found == nil || hasValue {
			continue
		}
		if boolean, ok := found.Value.(interface{ IsBoolFlag() bool }); ok && boolean.IsBoolFlag() {
			continue
		}
		if i+1 < len(args) {
			i++
			flags = append(flags, args[i])
		}
	}

	// The separator matters: without it a positional beginning with a dash —
	// an id like `-7` — would be read as a flag on the second pass.
	return append(append(flags, "--"), positional...)
}

// client builds a client for a command that needs a token, refusing early and
// with the repair rather than letting the node answer 401 — the advice is the
// same either way and a round trip buys nothing.
func (c *common) client() (*Client, *Config, error) {
	cfg, warning, err := LoadConfig()
	if err != nil {
		return nil, nil, err
	}
	if warning != "" && !c.asJSON {
		fmt.Fprintf(os.Stderr, "blazie: %s\n", warning)
	}

	baseURL, _ := ResolveBaseURL(c.url, cfg)
	token, _ := ResolveToken(cfg)

	if token == "" {
		return nil, cfg, &Refusal{
			Problem: "no_token",
			Repair: "There is no token here. Run `blazie login`, or set BLAZIE_TOKEN to one " +
				"the node minted.",
		}
	}

	return NewClient(baseURL, token), cfg, nil
}

// ── login ───────────────────────────────────────────────────────────────────

func cmdLogin(ctx context.Context, args []string, out, errOut io.Writer) (bool, error) {
	flags := newFlags("login")
	noBrowser := flags.set.Bool("no-browser", false, "never offer to open a browser")
	if err := flags.parse(args); err != nil {
		return false, err
	}

	cfg, _, err := LoadConfig()
	if err != nil {
		return flags.asJSON, err
	}

	baseURL, _ := ResolveBaseURL(flags.url, cfg)
	client := NewClient(baseURL, "")
	s := styleFor(out)

	start, err := client.BeginDevice(ctx)
	if err != nil {
		return flags.asJSON, err
	}

	if flags.asJSON {
		// A script driving this wants the code and the URI so it can show them
		// somewhere else; it still waits here, and still gets the token.
		writeJSON(out, map[string]any{
			"user_code":        start.UserCode,
			"verification_uri": start.VerificationURI,
			"interval":         start.Interval,
			"expires_in":       start.ExpiresIn,
		})
	} else {
		fmt.Fprintf(out, "\nSign in at %s and enter this code:\n", s.bold(start.VerificationURI))
		WriteUserCode(out, start.UserCode)
		fmt.Fprintf(out, "\n%s\n",
			s.dim(fmt.Sprintf("it is good for %s", roughly(start.ExpiresIn))))

		if !*noBrowser && confirm(out, os.Stdin, "Open that page now?") {
			if err := openBrowser(start.VerificationURI); err != nil {
				fmt.Fprintf(errOut, "blazie: could not open a browser (%v) — open it yourself.\n", err)
			}
		}

		fmt.Fprintf(out, "\n%s\n",
			s.dim(fmt.Sprintf("waiting — checking every %ds", max(start.Interval, 1))))
	}

	admitted, err := client.AwaitDevice(ctx, start, func(d time.Duration, changed bool) {
		// Only said when it changes. The node asking for a slower cadence is
		// the one thing during the wait a person might otherwise read as this
		// having hung.
		if changed && !flags.asJSON {
			fmt.Fprintf(out, "%s\n",
				s.dim(fmt.Sprintf("the node asked to slow down — now every %ds", int(d.Seconds()))))
		}
	})
	if err != nil {
		return flags.asJSON, err
	}

	cfg.Token = admitted.Token
	cfg.Login = admitted.Login
	if flags.url != "" {
		// A node named on the command line at sign-in is the node this token
		// belongs to, so it is remembered — a token from one node and a URL
		// from another is a 401 nobody can explain.
		cfg.BaseURL = flags.url
	}
	if err := cfg.Save(); err != nil {
		return flags.asJSON, err
	}

	if flags.asJSON {
		writeJSON(out, map[string]any{"login": admitted.Login, "config": cfg.Path()})
		return flags.asJSON, nil
	}

	fmt.Fprintf(out, "\nSigned in as %s.\n", s.bold(admitted.Login))
	fmt.Fprintf(out, "%s\n", s.dim(fmt.Sprintf("token stored in %s, mode 0600", cfg.Path())))
	return flags.asJSON, nil
}

// ── logout ──────────────────────────────────────────────────────────────────

func cmdLogout(args []string, out io.Writer) (bool, error) {
	flags := newFlags("logout")
	if err := flags.parse(args); err != nil {
		return false, err
	}

	cfg, _, err := LoadConfig()
	if err != nil {
		return flags.asJSON, err
	}

	had := cfg.Token != ""
	if err := cfg.Forget(); err != nil {
		return flags.asJSON, err
	}

	if flags.asJSON {
		writeJSON(out, map[string]any{"forgotten": had, "config": cfg.Path()})
		return flags.asJSON, nil
	}

	if !had {
		fmt.Fprintln(out, "There was no token here.")
	} else {
		fmt.Fprintf(out, "Token forgotten. It is still valid on the node — %s\n",
			styleFor(out).dim("a bearer credential is the caller until it is revoked there."))
	}
	return flags.asJSON, nil
}

// ── whoami ──────────────────────────────────────────────────────────────────

func cmdWhoami(ctx context.Context, args []string, out io.Writer) (bool, error) {
	flags := newFlags("whoami")
	if err := flags.parse(args); err != nil {
		return false, err
	}

	client, _, err := flags.client()
	if err != nil {
		return flags.asJSON, err
	}

	me, err := client.Me(ctx)
	if err != nil {
		return flags.asJSON, err
	}

	if flags.asJSON {
		writeJSON(out, me)
		return flags.asJSON, nil
	}

	s := styleFor(out)
	login := me.Login
	if login == "" {
		login = s.dim("(no login recorded for this token)")
	}

	fmt.Fprintf(out, "%-9s %s\n", "login", s.bold(login))
	// The caller is the fingerprint of the token, and it is what a grant is
	// written against — so it is the thing to paste when asking for one.
	fmt.Fprintf(out, "%-9s %s\n", "caller", me.Caller)
	fmt.Fprintf(out, "%-9s %s\n", "node", client.BaseURL)
	fmt.Fprintf(out, "%-9s %s\n", "ledgers", plural(len(me.Ledgers), "ledger", "ledgers"))
	return flags.asJSON, nil
}

// ── ledger ls ───────────────────────────────────────────────────────────────

func cmdLedger(ctx context.Context, args []string, out io.Writer) (bool, error) {
	// Flags first, so `blazie ledger --json ls` and `blazie ledger ls --json`
	// are the same command rather than one of them being a mystery.
	flags := newFlags("ledger ls")
	if err := flags.parse(args); err != nil {
		return false, err
	}

	rest := flags.set.Args()
	switch {
	case len(rest) == 2 && rest[0] == "new":
		return cmdLedgerNew(ctx, flags, rest[1], out)

	case len(rest) == 1 && rest[0] == "ls":
		// fall through to the listing below

	default:
		return flags.asJSON, &usageError{&Refusal{
			Problem: "unknown_command",
			Repair: "There are two: `blazie ledger ls` for the ledgers this token may " +
				"name, and `blazie ledger new <name>` to take one.",
		}}
	}

	client, _, err := flags.client()
	if err != nil {
		return flags.asJSON, err
	}

	me, err := client.Me(ctx)
	if err != nil {
		return flags.asJSON, err
	}

	if flags.asJSON {
		writeJSON(out, map[string]any{"ledgers": me.Ledgers})
		return flags.asJSON, nil
	}

	if len(me.Ledgers) == 0 {
		fmt.Fprintf(out, "%s\n", styleFor(out).dim(
			"This token may name no ledgers. Authorization here is which ledgers a caller "+
				"may name, so a grant has to be written for "+me.Caller+"."))
		return flags.asJSON, nil
	}

	for _, ledger := range me.Ledgers {
		fmt.Fprintln(out, ledger)
	}
	return flags.asJSON, nil
}

// cmdLedgerNew takes a name. Claiming grants it to whoever claimed it, which is
// the part a caller could never write for itself — every request is checked
// against the ledgers it may name, so a new one was refused before it could be
// created.
func cmdLedgerNew(ctx context.Context, flags *common, name string, out io.Writer) (bool, error) {
	client, _, err := flags.client()
	if err != nil {
		return flags.asJSON, err
	}

	at, err := client.Claim(ctx, name)
	if err != nil {
		return flags.asJSON, err
	}

	if flags.asJSON {
		writeJSON(out, map[string]any{"ledger": name, "name": at})
		return flags.asJSON, nil
	}

	s := styleFor(out)
	fmt.Fprintf(out, "%s\n", s.bold(name))
	fmt.Fprintf(out, "%s\n", s.dim("yours. run against it with `blazie run "+name+" '<lua>'`"))
	return flags.asJSON, nil
}

// ── run ─────────────────────────────────────────────────────────────────────

func cmdRun(ctx context.Context, args []string, out io.Writer) (bool, error) {
	flags := newFlags("run")
	file := flags.set.String("f", "", "read the lua from a file, or - for stdin")
	pin := flags.set.String("at", "", "read at this snapshot name, as json")
	as := flags.set.String("as", "", "formula (default) or job — a job gets a clock and http")
	if err := flags.parse(args); err != nil {
		return false, err
	}

	rest := flags.set.Args()
	if len(rest) == 0 {
		return flags.asJSON, &usageError{&Refusal{
			Problem: "no_ledger",
			Repair: "Name the ledger to run against — `blazie run <ledger> '<lua>'` or " +
				"`blazie run <ledger> -f script.lua`.",
		}}
	}

	ledger := rest[0]
	source, err := sourceFrom(rest[1:], *file)
	if err != nil {
		return flags.asJSON, err
	}

	client, _, err := flags.client()
	if err != nil {
		return flags.asJSON, err
	}

	opts := RunOptions{As: *as}
	if *pin != "" {
		if err := json.Unmarshal([]byte(*pin), &opts.Name); err != nil {
			return flags.asJSON, &usageError{&Refusal{
				Problem: "bad_name",
				Repair: "A snapshot name is the json object a run hands back, like " +
					`{"main":42}. ` + fmt.Sprintf("%q is not one.", *pin),
			}}
		}
	}

	result, err := client.Run(ctx, ledger, source, opts)
	if err != nil {
		return flags.asJSON, err
	}

	if flags.asJSON {
		writeJSON(out, result)
		return flags.asJSON, nil
	}

	RenderRun(out, result)
	return flags.asJSON, nil
}

// sourceFrom takes the Lua from wherever it was given: an argument, a file, or
// stdin. Both at once is refused rather than one silently winning — a script
// that meant `-f` and also passed a string has a bug, and picking for it hides
// the bug rather than the ambiguity.
func sourceFrom(args []string, file string) (string, error) {
	inline := strings.TrimSpace(strings.Join(args, " "))

	switch {
	case inline != "" && file != "":
		return "", &usageError{&Refusal{
			Problem: "two_sources",
			Repair:  "Give the lua as an argument or with -f, not both.",
		}}

	case file == "-":
		read, err := io.ReadAll(os.Stdin)
		if err != nil {
			return "", &Refusal{Problem: "unreadable", Repair: err.Error()}
		}
		return string(read), nil

	case file != "":
		read, err := os.ReadFile(file)
		if err != nil {
			return "", &Refusal{
				Problem: "unreadable",
				Repair:  fmt.Sprintf("Could not read %s: %v", file, err),
			}
		}
		return string(read), nil

	case inline != "":
		return inline, nil

	default:
		return "", &usageError{&Refusal{
			Problem: "no_source",
			Repair: "Give the lua to run — `blazie run <ledger> 'ada.height = 180'`, " +
				"`-f script.lua`, or `-f -` for stdin.",
		}}
	}
}

// ── watch ───────────────────────────────────────────────────────────────────

func cmdWatch(ctx context.Context, args []string, out, errOut io.Writer) (bool, error) {
	flags := newFlags("watch")
	file := flags.set.String("f", "", "read the lua from a file, or - for stdin")
	if err := flags.parse(args); err != nil {
		return false, err
	}

	ledgers := flags.set.Args()
	if len(ledgers) == 0 {
		return flags.asJSON, &usageError{&Refusal{
			Problem: "no_ledger",
			Repair: "Name the ledger to watch, and the lua to keep answering — " +
				"`blazie watch <ledger> '<lua>'`.",
		}}
	}

	client, _, err := flags.client()
	if err != nil {
		return flags.asJSON, err
	}

	// The first argument is the ledger, and everything after it is the chunk —
	// the same shape as `run`, because watching IS a run kept and a client that
	// learned one should not discover the other wants something else.
	source, err := sourceFrom(ledgers[1:], *file)
	if err != nil {
		return flags.asJSON, err
	}

	return flags.asJSON, client.Watch(ctx, out, errOut, ledgers[:1], source, flags.asJSON)
}

// ── config ──────────────────────────────────────────────────────────────────

func cmdConfig(args []string, out io.Writer) (bool, error) {
	flags := newFlags("config")
	if err := flags.parse(args); err != nil {
		return false, err
	}

	cfg, warning, err := LoadConfig()
	if err != nil {
		return flags.asJSON, err
	}

	baseURL, urlFrom := ResolveBaseURL(flags.url, cfg)
	token, tokenFrom := ResolveToken(cfg)

	mode := "—"
	if info, statErr := os.Stat(cfg.Path()); statErr == nil {
		mode = fmt.Sprintf("%04o", info.Mode().Perm())
	}

	if flags.asJSON {
		// The token is never in here, in any mode. A CLI that will print a
		// credential on request is a credential in a CI log.
		writeJSON(out, map[string]any{
			"config":        cfg.Path(),
			"mode":          mode,
			"base_url":      baseURL,
			"base_url_from": urlFrom,
			"token_present": token != "",
			"token_from":    tokenFrom,
			"login":         cfg.Login,
			"warning":       warning,
		})
		return flags.asJSON, nil
	}

	s := styleFor(out)
	fmt.Fprintf(out, "%-10s %s %s\n", "config", cfg.Path(), s.dim("mode "+mode))
	fmt.Fprintf(out, "%-10s %s %s\n", "node", baseURL, s.dim("from "+urlFrom))

	switch {
	case token == "":
		fmt.Fprintf(out, "%-10s %s\n", "token", s.dim("none — run `blazie login`"))
	case cfg.Login != "" && tokenFrom == "config":
		fmt.Fprintf(out, "%-10s present, %s %s\n", "token", cfg.Login, s.dim("from "+tokenFrom))
	default:
		fmt.Fprintf(out, "%-10s present %s\n", "token", s.dim("from "+tokenFrom))
	}

	if warning != "" {
		fmt.Fprintf(out, "\n%s\n", indent(wrap(warning, 72), "    "))
	}
	return flags.asJSON, nil
}

// ── values off a command line ───────────────────────────────────────────────

// parseValue decides whether an argument is JSON or a string.
//
// A command line has only strings on it, and a fact's value is any JSON, so
// something has to guess. The guess is: if it parses as JSON, it is JSON.
// That makes `blazie write l 1 height 180` write the number and not the text,
// which is nearly always what was meant — and `--string` is there for the times
// it is not, because a version number like `1.20` is a string that parses.
func parseValue(raw string, forceString bool) any {
	if forceString {
		return raw
	}

	var decoded any
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return raw
	}
	return decoded
}

// parseID is the same idea, narrowed. An id travels as a number or a string and
// nothing else, so only whole numbers are recognised — a float or an object
// would be refused at the boundary, and refusing here says so sooner.
func parseID(raw string, forceString bool) any {
	if forceString {
		return raw
	}
	if n, err := strconv.ParseInt(raw, 10, 64); err == nil {
		return n
	}
	return raw
}

func isSet(set *flag.FlagSet, name string) bool {
	found := false
	set.Visit(func(f *flag.Flag) {
		if f.Name == name {
			found = true
		}
	})
	return found
}

// ── the browser, and asking first ───────────────────────────────────────────

// confirm asks a yes/no question, defaulting to yes.
//
// Only when both ends are a terminal. In a pipe or a CI job there is nobody to
// answer and nowhere to open a browser, so it answers no and the verification
// URI printed above is the whole of what is needed.
func confirm(out io.Writer, in *os.File, question string) bool {
	if !isTTY(out) || !isTTY(in) {
		return false
	}

	fmt.Fprintf(out, "\n%s [Y/n] ", question)

	line, err := bufio.NewReader(in).ReadString('\n')
	if err != nil && line == "" {
		return false
	}

	switch strings.ToLower(strings.TrimSpace(line)) {
	case "", "y", "yes":
		return true
	default:
		return false
	}
}

func openBrowser(uri string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", uri).Start()
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", uri).Start()
	default:
		return exec.Command("xdg-open", uri).Start()
	}
}

func roughly(seconds int) string {
	switch {
	case seconds <= 0:
		return "a while"
	case seconds < 90:
		return fmt.Sprintf("%d seconds", seconds)
	default:
		return fmt.Sprintf("%d minutes", (seconds+30)/60)
	}
}

// ── usage ───────────────────────────────────────────────────────────────────

func writeUsage(out io.Writer) {
	s := styleFor(out)
	fmt.Fprintf(out, `%s — the backend agents run on, from the terminal.

%s
  blazie login              sign in on this machine, and keep the token
  blazie logout             forget the token here
  blazie whoami             who this token is, and what it may name
  blazie config             where the settings are and which node is in force

%s
  blazie ledger ls                the ledgers this token may name
  blazie ledger new <name>        take a name, and hold what you took
  blazie run <ledger> '<lua>'     run it, and print what it returned
  blazie run <ledger> -f <file>   the same, from a file (- for stdin)
  blazie watch <ledger> '<lua>'   the same chunk, answered again as things land

%s
  ada.height = 180                     a field is a field
  ada.friend = grace                   an edge is a field holding an entity
  ada.height = nil                     unsay it; what was true stays true
  for p in each { height = 180 } do    find
  at(42).ada.height                    what it was then

%s
  -f <file>            read the lua from a file, or - for stdin (run, watch)
  --at <name>          read at this snapshot, as json             (run)
  --as job             give it a clock and http                   (run)
  --json               print what the node said, unshaped  (every command)
  --url <url>          the node to talk to
  --no-browser         never offer to open a browser           (login)

%s
  BLAZIE_URL      the node, unless --url says otherwise
  BLAZIE_TOKEN    a token, used in preference to the stored one
  BLAZIE_CONFIG   where the config lives, instead of ~/.config/blazie/config.json
`,
		s.bold("blazie"),
		s.bold("Signing in"),
		s.bold("Working"),
		s.bold("The whole language surface"),
		s.bold("Flags"),
		s.bold("Environment"))
}
