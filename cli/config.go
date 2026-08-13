package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Where a token lives between runs.
//
// A file rather than the system keychain, because the keychain differs on every
// platform and this has to work the same over SSH, in a container and on a
// laptop. That is a real trade and it is stated rather than hidden: anything
// running as this user can read the token. Mode 0600 keeps out other users and
// nothing more.

const defaultBaseURL = "http://127.0.0.1:4000"

// Config is what survives between runs. The token is the only secret in it.
type Config struct {
	BaseURL string `json:"base_url,omitempty"`
	Token   string `json:"token,omitempty"`
	Login   string `json:"login,omitempty"`

	// Where this was read from, so `blazie config` can say so. Not serialised.
	path string
}

// ConfigPath is the file a token is kept in.
//
// BLAZIE_CONFIG wins so a test — and a person with two nodes — can point
// somewhere else without arguing with XDG.
func ConfigPath() (string, error) {
	if p := os.Getenv("BLAZIE_CONFIG"); p != "" {
		return p, nil
	}

	if dir := os.Getenv("XDG_CONFIG_HOME"); dir != "" {
		return filepath.Join(dir, "blazie", "config.json"), nil
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return "", &Refusal{
			Problem: "no_home",
			Repair: "Could not find a home directory to keep the config in. " +
				"Set BLAZIE_CONFIG to the file blazie should use.",
		}
	}

	return filepath.Join(home, ".config", "blazie", "config.json"), nil
}

// LoadConfig reads the config, or hands back an empty one.
//
// A missing file is not a failure — it is what every first run looks like. A
// malformed file IS a failure, and says which file, because silently starting
// over would throw away a token somebody is still holding.
//
// The second return is a warning about the file itself rather than its
// contents: a token readable by every account on the machine is worth saying
// out loud, and is not worth refusing to run over.
func LoadConfig() (*Config, string, error) {
	path, err := ConfigPath()
	if err != nil {
		return nil, "", err
	}

	cfg := &Config{path: path}

	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return cfg, "", nil
	}
	if err != nil {
		return nil, "", &Refusal{
			Problem: "config_unreadable",
			Repair:  fmt.Sprintf("Could not read %s: %v.", path, err),
		}
	}

	if err := json.Unmarshal(raw, cfg); err != nil {
		return nil, "", &Refusal{
			Problem: "config_malformed",
			Repair: fmt.Sprintf("%s is not valid JSON (%v). Fix it, or delete it and "+
				"run `blazie login` again.", path, err),
		}
	}
	cfg.path = path

	var warning string
	if info, err := os.Stat(path); err == nil && info.Mode().Perm()&0o077 != 0 {
		warning = fmt.Sprintf("%s is mode %04o — every account on this machine can read the "+
			"token in it. `chmod 600 %s`.", path, info.Mode().Perm(), path)
	}

	return cfg, warning, nil
}

// Save writes the config back at mode 0600.
//
// Written to a neighbouring temp file and renamed, so an interrupted write
// leaves the old token rather than half of a new one. The chmod is explicit
// because the mode passed to OpenFile is masked by the process umask, and a
// umask of 0 would otherwise produce a world-readable token.
func (c *Config) Save() error {
	path := c.path
	if path == "" {
		p, err := ConfigPath()
		if err != nil {
			return err
		}
		path = p
		c.path = p
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return &Refusal{
			Problem: "config_undirectable",
			Repair:  fmt.Sprintf("Could not make %s: %v.", dir, err),
		}
	}

	raw, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')

	tmp, err := os.CreateTemp(dir, ".config-*.json")
	if err != nil {
		return &Refusal{
			Problem: "config_unwritable",
			Repair:  fmt.Sprintf("Could not write into %s: %v.", dir, err),
		}
	}
	name := tmp.Name()

	fail := func(err error) error {
		tmp.Close()
		os.Remove(name)
		return &Refusal{
			Problem: "config_unwritable",
			Repair:  fmt.Sprintf("Could not write %s: %v.", path, err),
		}
	}

	if _, err := tmp.Write(raw); err != nil {
		return fail(err)
	}
	if err := tmp.Chmod(0o600); err != nil {
		return fail(err)
	}
	if err := tmp.Close(); err != nil {
		return fail(err)
	}
	if err := os.Rename(name, path); err != nil {
		os.Remove(name)
		return &Refusal{
			Problem: "config_unwritable",
			Repair:  fmt.Sprintf("Could not put %s in place: %v.", path, err),
		}
	}

	return nil
}

// Forget drops the token and login, keeping anything else — a base URL somebody
// set is a setting, not a credential, and signing out should not lose it.
func (c *Config) Forget() error {
	c.Token = ""
	c.Login = ""
	return c.Save()
}

// Path is where this config was read from or will be written to.
func (c *Config) Path() string { return c.path }

// ResolveBaseURL applies the order of precedence, and says which one won.
//
// Said out loud because the commonest confusion with a CLI that has both a flag
// and an environment variable is not knowing which is in force.
func ResolveBaseURL(flagURL string, cfg *Config) (url, source string) {
	switch {
	case flagURL != "":
		return flagURL, "--url"
	case os.Getenv("BLAZIE_URL") != "":
		return os.Getenv("BLAZIE_URL"), "BLAZIE_URL"
	case cfg != nil && cfg.BaseURL != "":
		return cfg.BaseURL, "config"
	default:
		return defaultBaseURL, "default"
	}
}

// ResolveToken is the same idea for the credential. There is no flag: a token
// on a command line ends up in shell history and in `ps`.
func ResolveToken(cfg *Config) (token, source string) {
	if t := os.Getenv("BLAZIE_TOKEN"); t != "" {
		return t, "BLAZIE_TOKEN"
	}
	if cfg != nil && cfg.Token != "" {
		return cfg.Token, "config"
	}
	return "", ""
}
