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
# Pinned to the local montology rather than to GitHub main, because main is
# behind: `onto add` there refuses without `--pos` and does not accept `--pos`,
# so no word can be recorded by anyone. The fix is already in the working tree
# next door; this points at it until that is pushed.
# So `$@` in a recipe body carries each argument whole, which is what keeps a
# quoted sentence a sentence instead of a dozen positional arguments.
set positional-arguments

monty := "uv run --project " + justfile_directory() + "/../montology/.monty/cli monty"

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
# `{{ARGS}}` unquoted splits a quoted definition into words, so `onto add`
# arrived as a dozen positional arguments and was refused for having too many.
# Just's own quoting is what keeps a sentence a sentence.
monty *ARGS:
    @{{monty}} "$@"


# Regenerate the README banner from the running site, so it cannot drift from
# the hero it is meant to look like. Needs `just web` running on :3111.
banner:
    @echo "open http://localhost:3111/banner at 1200x420 and capture to priv/static/brand/banner.png"
    @echo "the page is web/app/banner/page.tsx — it renders the same shader and the same wordmark"

# The console, in development.
web:
    cd web && pnpm dev --port 3111

# Build the console for a static host.
web-build:
    cd web && pnpm build

# Ship the console to Cloudflare Pages. The account id is explicit because
# this wrangler login can see two accounts and picking the wrong one is silent.
web-deploy: web-build
    cd web && CLOUDFLARE_ACCOUNT_ID=6d4b74aeb10f455fbf88141901e7595d \
      npx wrangler pages deploy out --project-name blazie --branch main --commit-dirty=true
