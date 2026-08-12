# Lazy River. Homebrew installs erlang keg-only, so every recipe needs it on
# PATH — outside `just`, elixir fails with `exec: erl: not found`.
export PATH := "/opt/homebrew/opt/erlang/bin:" + env_var('PATH')

monty := "uvx --from " + justfile_directory() + "/../montology/.monty/cli monty"

_default:
    @just --list

# What must pass before a commit.
check: test onto-scan

test:
    mix test

build:
    mix compile --warnings-as-errors

# Is this name free, ours, or ruled on? Run BEFORE naming anything.
onto-check NAME:
    @{{monty}} onto check {{NAME}}

# The gate: collisions, code resolution, prose drift.
onto-scan:
    @{{monty}} lint

# Regenerate the words skill from the database. Never hand-edit the render.
onto-sync:
    @{{monty}} sync

# Any monty command through the pinned engine.
monty *ARGS:
    @{{monty}} {{ARGS}}
