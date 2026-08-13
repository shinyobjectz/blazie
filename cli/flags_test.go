package main

import (
	"flag"
	"io"
	"strings"
	"testing"
)

// Go's flag package stops at the first argument that is not a flag, so
// `blazie ask tenant-7 --attribute height` would reach the node as three
// worlds, one of them called "--attribute". Measured against a live node
// before this existed: the refusal was correct, carried its repair, and was
// still the wrong thing to hand somebody who typed the obvious command.

func testFlags() (*flag.FlagSet, *string, *bool) {
	set := flag.NewFlagSet("test", flag.ContinueOnError)
	set.SetOutput(io.Discard)
	attribute := set.String("attribute", "", "")
	stringly := set.Bool("string", false, "")
	return set, attribute, stringly
}

func TestFlagsMayFollowTheLedgers(t *testing.T) {
	set, attribute, _ := testFlags()

	if err := set.Parse(permute(set, []string{"tenant-7", "--attribute", "height"})); err != nil {
		t.Fatal(err)
	}
	if *attribute != "height" {
		t.Fatalf("got attribute %q", *attribute)
	}
	if got := set.Args(); len(got) != 1 || got[0] != "tenant-7" {
		t.Fatalf("got positionals %v", got)
	}
}

func TestFlagsMayBeInterleaved(t *testing.T) {
	set, attribute, stringly := testFlags()

	args := []string{"tenant-7", "--string", "other-world", "--attribute=height", "third"}
	if err := set.Parse(permute(set, args)); err != nil {
		t.Fatal(err)
	}
	if *attribute != "height" || !*stringly {
		t.Fatalf("got attribute %q, string %v", *attribute, *stringly)
	}
	if got := set.Args(); len(got) != 3 {
		t.Fatalf("got positionals %v", got)
	}
}

// A boolean flag does not swallow the argument after it, or the world would
// vanish into `--string`.
func TestABooleanFlagDoesNotEatTheNextArgument(t *testing.T) {
	set, _, stringly := testFlags()

	if err := set.Parse(permute(set, []string{"--string", "tenant-7"})); err != nil {
		t.Fatal(err)
	}
	if !*stringly {
		t.Fatal("the flag was not set")
	}
	if got := set.Args(); len(got) != 1 || got[0] != "tenant-7" {
		t.Fatalf("got positionals %v", got)
	}
}

// An id can begin with a dash, and `--` is how it is said so.
func TestAfterADoubleDashEverythingIsPositional(t *testing.T) {
	set, attribute, _ := testFlags()

	if err := set.Parse(permute(set, []string{"--attribute", "height", "--", "-7"})); err != nil {
		t.Fatal(err)
	}
	if *attribute != "height" {
		t.Fatalf("got attribute %q", *attribute)
	}
	if got := set.Args(); len(got) != 1 || got[0] != "-7" {
		t.Fatalf("got positionals %v", got)
	}
}

// An unknown flag is left where it is, so the parser complains about it rather
// than this quietly guessing what it meant.
func TestAnUnknownFlagStillFails(t *testing.T) {
	set, _, _ := testFlags()

	if err := set.Parse(permute(set, []string{"tenant-7", "--nonesuch"})); err == nil {
		t.Fatal("an unknown flag should be an error")
	}
}

// ── flags in front of the command ───────────────────────────────────────────

func TestGlobalFlagsMayComeBeforeTheCommand(t *testing.T) {
	command, rest, err := hoistGlobals([]string{"--url", "http://node", "--json", "ask", "tenant-7"})
	if err != nil {
		t.Fatal(err)
	}
	if command != "ask" {
		t.Fatalf("got command %q", command)
	}

	set := newFlags("ask")
	if err := set.parse(rest); err != nil {
		t.Fatal(err)
	}
	if set.url != "http://node" || !set.asJSON {
		t.Fatalf("got url %q json %v", set.url, set.asJSON)
	}
	if got := set.set.Args(); len(got) != 1 || got[0] != "tenant-7" {
		t.Fatalf("got positionals %v", got)
	}
}

func TestVersionAndHelpAreCommandsSpelledLikeFlags(t *testing.T) {
	for _, arg := range []string{"--version", "-v", "--help", "-h"} {
		command, _, err := hoistGlobals([]string{arg})
		if err != nil || command != arg {
			t.Fatalf("%s gave command %q, err %v", arg, command, err)
		}
	}
}

// A per-command flag in front of the command is a mistake, and the repair says
// where it belongs rather than only that it was wrong.
func TestAPerCommandFlagInFrontSaysWhereItBelongs(t *testing.T) {
	_, _, err := hoistGlobals([]string{"--attribute", "height", "ask", "tenant-7"})

	usage, ok := err.(*usageError)
	if !ok {
		t.Fatalf("got %T", err)
	}
	if !strings.Contains(usage.Repair, "after the command") {
		t.Fatalf("got %q", usage.Repair)
	}
}

func TestFlagsWithNoCommandAtAllAskForOne(t *testing.T) {
	_, _, err := hoistGlobals([]string{"--json"})

	usage, ok := err.(*usageError)
	if !ok {
		t.Fatalf("got %T", err)
	}
	if usage.Problem != "no_command" {
		t.Fatalf("got %q", usage.Problem)
	}
}
