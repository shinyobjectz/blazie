package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The config holds a bearer credential, and a bearer credential is the caller
// until it is revoked. Its mode is therefore part of the contract rather than a
// detail, and is asserted rather than assumed.

func TestSaveWritesAtModeSixHundred(t *testing.T) {
	path := tempConfig(t)

	cfg := &Config{Token: "secret", Login: "shinyobjectz"}
	if err := cfg.Save(); err != nil {
		t.Fatalf("saving: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("the config was not written: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("the token landed at mode %04o, not 0600", perm)
	}
}

// The mode passed at creation is masked by the process umask, so a permissive
// umask is exactly the case the explicit chmod exists for. Proven under one.
func TestSaveUnderAPermissiveUmaskIsStillSixHundred(t *testing.T) {
	restore := withUmask(t, 0)
	defer restore()

	tempConfig(t)
	cfg := &Config{Token: "secret"}
	if err := cfg.Save(); err != nil {
		t.Fatalf("saving: %v", err)
	}

	path, _ := ConfigPath()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("the config was not written: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("under umask 0 the token landed at mode %04o, not 0600", perm)
	}
}

func TestLoadRoundTripsWhatWasSaved(t *testing.T) {
	tempConfig(t)

	saved := &Config{BaseURL: "https://node.example", Token: "secret", Login: "shinyobjectz"}
	if err := saved.Save(); err != nil {
		t.Fatalf("saving: %v", err)
	}

	loaded, warning, err := LoadConfig()
	if err != nil {
		t.Fatalf("loading: %v", err)
	}
	if warning != "" {
		t.Fatalf("a file this command just wrote should warn about nothing, got %q", warning)
	}
	if loaded.Token != "secret" || loaded.Login != "shinyobjectz" || loaded.BaseURL != "https://node.example" {
		t.Fatalf("got %+v", loaded)
	}
}

// A first run has no config, and that is not a failure.
func TestLoadOfAMissingConfigIsEmptyRatherThanAnError(t *testing.T) {
	tempConfig(t)

	cfg, warning, err := LoadConfig()
	if err != nil {
		t.Fatalf("a missing config should be an empty one: %v", err)
	}
	if cfg.Token != "" || warning != "" {
		t.Fatalf("got %+v, warning %q", cfg, warning)
	}
}

// A broken config IS a failure, and must name the file — starting over silently
// would throw away a token somebody is still holding.
func TestLoadOfAMalformedConfigRefusesAndNamesTheFile(t *testing.T) {
	path := tempConfig(t)
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}

	_, _, err := LoadConfig()
	refusal := mustRefusal(t, err)

	if refusal.Problem != "config_malformed" {
		t.Fatalf("got problem %q", refusal.Problem)
	}
	if !strings.Contains(refusal.Repair, path) {
		t.Fatalf("the repair has to name the file, got %q", refusal.Repair)
	}
	if !strings.Contains(refusal.Repair, "blazie login") {
		t.Fatalf("the repair has to say what to do, got %q", refusal.Repair)
	}
}

func TestLoadWarnsAboutAWorldReadableToken(t *testing.T) {
	path := tempConfig(t)
	if err := os.WriteFile(path, []byte(`{"token":"secret"}`), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, warning, err := LoadConfig()
	if err != nil {
		t.Fatalf("a readable config still loads: %v", err)
	}
	if cfg.Token != "secret" {
		t.Fatal("the token should still have been read")
	}
	if !strings.Contains(warning, "chmod 600") {
		t.Fatalf("the warning has to carry its own repair, got %q", warning)
	}
}

// Signing out drops the credential and keeps the setting. Losing the node URL
// on logout would be losing something that was never a secret.
func TestForgetKeepsTheBaseURL(t *testing.T) {
	tempConfig(t)

	cfg := &Config{BaseURL: "https://node.example", Token: "secret", Login: "shinyobjectz"}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	if err := cfg.Forget(); err != nil {
		t.Fatal(err)
	}

	loaded, _, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Token != "" || loaded.Login != "" {
		t.Fatalf("the credential survived a logout: %+v", loaded)
	}
	if loaded.BaseURL != "https://node.example" {
		t.Fatalf("the node was forgotten too: %+v", loaded)
	}
}

func TestResolutionOrderIsFlagThenEnvironmentThenConfig(t *testing.T) {
	cfg := &Config{BaseURL: "https://from-config"}

	t.Setenv("BLAZIE_URL", "")
	if url, from := ResolveBaseURL("", cfg); url != "https://from-config" || from != "config" {
		t.Fatalf("got %s from %s", url, from)
	}

	t.Setenv("BLAZIE_URL", "https://from-env")
	if url, from := ResolveBaseURL("", cfg); url != "https://from-env" || from != "BLAZIE_URL" {
		t.Fatalf("got %s from %s", url, from)
	}

	if url, from := ResolveBaseURL("https://from-flag", cfg); url != "https://from-flag" || from != "--url" {
		t.Fatalf("got %s from %s", url, from)
	}

	t.Setenv("BLAZIE_URL", "")
	if url, from := ResolveBaseURL("", &Config{}); url != defaultBaseURL || from != "default" {
		t.Fatalf("got %s from %s", url, from)
	}
}

func TestATokenInTheEnvironmentBeatsTheStoredOne(t *testing.T) {
	cfg := &Config{Token: "stored"}

	t.Setenv("BLAZIE_TOKEN", "")
	if token, from := ResolveToken(cfg); token != "stored" || from != "config" {
		t.Fatalf("got %s from %s", token, from)
	}

	t.Setenv("BLAZIE_TOKEN", "from-env")
	if token, from := ResolveToken(cfg); token != "from-env" || from != "BLAZIE_TOKEN" {
		t.Fatalf("got %s from %s", token, from)
	}

	t.Setenv("BLAZIE_TOKEN", "")
	if token, from := ResolveToken(&Config{}); token != "" || from != "" {
		t.Fatalf("got %s from %s", token, from)
	}
}

// tempConfig points the CLI at a throwaway config for the length of one test.
func tempConfig(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "blazie", "config.json")
	t.Setenv("BLAZIE_CONFIG", path)
	return path
}
