# blazie. Homebrew installs erlang keg-only, so every recipe needs it on
# PATH — outside `just`, elixir fails with `exec: erl: not found`.
export PATH := "/opt/homebrew/opt/erlang/bin:" + env_var('PATH')

# The same montology CI runs, so the gate says the same thing in both places.
# It used to point at the sibling submodule, which is right until that checkout
# is ahead of what CI can fetch — and then the two versions render different
# surface hashes for the same repo, no single words skill satisfies both, and
# the gate is red somewhere no matter what you do. Measured: montology sat two
# commits ahead, local said the render was stale and CI said the opposite, with
# the two hashes exactly swapped.
#
# To develop montology against this repo, point MONTY at the checkout:
#   just --set monty "uvx --from ../montology/.monty/cli monty" check
monty := "uvx --from 'git+https://github.com/socialite-ml/montology@main#subdirectory=.monty/cli' monty"

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
