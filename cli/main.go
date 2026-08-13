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

	command, rest := args[0], args[1:]

	var (
		err    error
		asJSON bool
	)

	switch command {
	case "login":
		asJSON, err = cmdLogin(ctx, rest, out, errOut)
	case "logout":
		asJSON, err = cmdLogout(rest, out)
	case "whoami":
		asJSON, err = cmdWhoami(ctx, rest, out)
	case "ledger":
		asJSON, err = cmdLedger(ctx, rest, out)
	case "ask":
		asJSON, err = cmdAsk(ctx, rest, out)
	case "write":
		asJSON, err = cmdWrite(ctx, rest, out)
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
	if err := c.set.Parse(args); err != nil {
		return &usageError{&Refusal{
			Problem: "bad_flags",
			Repair:  fmt.Sprintf("%v. Run `blazie help`.", err),
		}}
	}
	return nil
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
	if len(args) == 0 || args[0] != "ls" {
		return false, &usageError{&Refusal{
			Problem: "unknown_command",
			Repair:  "The only one is `blazie ledger ls` — the ledgers this token may name.",
		}}
	}

	flags := newFlags("ledger ls")
	if err := flags.parse(args[1:]); err != nil {
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

// ── ask ─────────────────────────────────────────────────────────────────────

func cmdAsk(ctx context.Context, args []string, out io.Writer) (bool, error) {
	flags := newFlags("ask")
	attribute := flags.set.String("attribute", "", "match this attribute")
	id := flags.set.String("id", "", "match this id")
	value := flags.set.String("value", "", "match this value")
	by := flags.set.String("by", "", "match facts produced by this formula or job")
	stringly := flags.set.Bool("string", false, "take --id and --value as strings, never as JSON")
	if err := flags.parse(args); err != nil {
		return false, err
	}

	ledgers := flags.set.Args()
	if len(ledgers) == 0 {
		return flags.asJSON, &usageError{&Refusal{
			Problem: "no_ledgers",
			Repair: "Name the ledgers to ask. Asking none is not asking everything — " +
				"`blazie ask <ledger> [<ledger>...]`.",
		}}
	}

	client, _, err := flags.client()
	if err != nil {
		return flags.asJSON, err
	}

	pattern := Pattern{Attribute: *attribute, By: *by}
	if isSet(flags.set, "id") {
		pattern.ID = parseID(*id, *stringly)
	}
	if isSet(flags.set, "value") {
		pattern.Value = parseValue(*value, *stringly)
	}

	// Two calls, because they are two operations: opening names the ledgers and
	// hands back the snapshot, and the ask puts the question to that snapshot.
	// The name is printed alongside the answer for the reason the name exists —
	// asking again at it gives these same facts forever.
	name, err := client.Open(ctx, ledgers)
	if err != nil {
		return flags.asJSON, err
	}

	facts, err := client.Ask(ctx, name, pattern)
	if err != nil {
		return flags.asJSON, err
	}

	if flags.asJSON {
		writeJSON(out, map[string]any{"name": name, "facts": facts})
		return flags.asJSON, nil
	}

	fmt.Fprintf(out, "%s\n\n", styleFor(out).dim(nameString(name)))
	RenderFacts(out, facts)
	return flags.asJSON, nil
}

// ── write ───────────────────────────────────────────────────────────────────

func cmdWrite(ctx context.Context, args []string, out io.Writer) (bool, error) {
	flags := newFlags("write")
	stringly := flags.set.Bool("string", false, "take the id and value as strings, never as JSON")
	if err := flags.parse(args); err != nil {
		return false, err
	}

	rest := flags.set.Args()
	if len(rest) != 4 {
		return flags.asJSON, &usageError{&Refusal{
			Problem: "incomplete_assertion",
			Repair: "A fact is an id, an attribute and a value, written into one ledger — " +
				"`blazie write <ledger> <id> <attribute> <value>`.",
		}}
	}

	ledger, id, attribute, value := rest[0], rest[1], rest[2], rest[3]

	client, _, err := flags.client()
	if err != nil {
		return flags.asJSON, err
	}

	// Three wide, always. A fact written from here came from outside and names
	// no formula — the node refuses `by` rather than dropping it, so there is
	// deliberately no flag for it.
	name, err := client.Write(ctx, ledger, []Assertion{{
		ID:        parseID(id, *stringly),
		Attribute: attribute,
		Value:     parseValue(value, *stringly),
	}})
	if err != nil {
		return flags.asJSON, err
	}

	if flags.asJSON {
		writeJSON(out, map[string]any{"name": name})
		return flags.asJSON, nil
	}

	s := styleFor(out)
	fmt.Fprintf(out, "%s\n", s.bold(nameString(name)))
	fmt.Fprintf(out, "%s\n", s.dim("the snapshot your fact is in — ask at it and you get it back"))
	return flags.asJSON, nil
}

// ── watch ───────────────────────────────────────────────────────────────────

func cmdWatch(ctx context.Context, args []string, out, errOut io.Writer) (bool, error) {
	flags := newFlags("watch")
	attribute := flags.set.String("attribute", "", "watch this attribute only")
	id := flags.set.String("id", "", "watch this id only")
	stringly := flags.set.Bool("string", false, "take --id as a string, never as JSON")
	if err := flags.parse(args); err != nil {
		return false, err
	}

	ledgers := flags.set.Args()
	if len(ledgers) == 0 {
		return flags.asJSON, &usageError{&Refusal{
			Problem: "no_ledgers",
			Repair: "Name the ledgers to watch. Watching none is not watching everything — " +
				"`blazie watch <ledger> [<ledger>...]`.",
		}}
	}

	client, _, err := flags.client()
	if err != nil {
		return flags.asJSON, err
	}

	pattern := Pattern{Attribute: *attribute}
	if isSet(flags.set, "id") {
		pattern.ID = parseID(*id, *stringly)
	}

	return flags.asJSON, client.Watch(ctx, out, errOut, ledgers, pattern, flags.asJSON)
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
	fmt.Fprintf(out, `%s — an immutable fact-log database, from the terminal.

%s
  blazie login              sign in on this machine, and keep the token
  blazie logout             forget the token here
  blazie whoami             who this token is, and what it may name
  blazie config             where the settings are and which node is in force

%s
  blazie ledger ls                        the ledgers this token may name
  blazie ask <ledger>...                  open, then put a question to the snapshot
  blazie write <ledger> <id> <attr> <val> one fact, and the snapshot it lands in
  blazie watch <ledger>...                the same question, answered again as facts land

%s
  --attribute <name>   match one attribute            (ask, watch)
  --id <id>            match one id                   (ask, watch)
  --value <value>      match one value                (ask)
  --by <name>          match what a formula or job produced   (ask)
  --string             take --id and --value as text, never as JSON
  --json               print what the node said, unshaped     (every command)
  --url <url>          the node to talk to
  --no-browser         never offer to open a browser          (login)

%s
  BLAZIE_URL      the node, unless --url says otherwise
  BLAZIE_TOKEN    a token, used in preference to the stored one
  BLAZIE_CONFIG   where the config lives, instead of ~/.config/blazie/config.json
`,
		s.bold("blazie"),
		s.bold("Signing in"),
		s.bold("The four operations"),
		s.bold("Flags"),
		s.bold("Environment"))
}
