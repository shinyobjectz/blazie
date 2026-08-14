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

CF_ACCOUNT := "6d4b74aeb10f455fbf88141901e7595d"

monty := "uv run --project " + justfile_directory() + "/../montology/.monty/cli monty"

_default:
    @just --list

# What must pass before a commit.
# What must pass before a commit — and the same things CI asks, in the same
# order. `format` was missing, so a green `just check` never implied a green CI:
# the build had been failing on formatting for long enough that nobody was
# reading it, which is how a gate stops being one.
check: format-check test control-test onto-scan onto-words-check mcp-skill-check

format-check:
    mix format --check-formatted

# The control plane, which holds every credential and creates billable
# infrastructure. It had no tests while the cluster had six hundred, and both
# bugs found in it were found by running it against live vendors and then
# checking the vendors. These assert on what gets SENT.
control-test:
    cd web && pnpm test

test:
    mix test

build:
    mix compile --warnings-as-errors

# Is this name free, ours, or ruled on? Run BEFORE naming anything.
# blazie's vocabulary, rendered where the worker can quote it. The MCP surface
# describes clusters and worlds to an agent, and those definitions already exist
# — retyping one makes a second copy that nothing compares.
onto-words:
    @python3 scripts/onto-words.py

onto-words-check:
    @python3 scripts/onto-words.py --check

# The skill an agent reads, rendered from the tool array the server dispatches
# on. Documentation of an interface that is written by hand is correct the day
# it is written and silently wrong afterwards.
mcp-skill:
    @node --experimental-strip-types --import ./web/test/run.ts scripts/mcp-skill.mts

mcp-skill-check:
    @node --experimental-strip-types --import ./web/test/run.ts scripts/mcp-skill.mts --check

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


# Ship the node. Hand-typed rsync and `systemctl restart` is how this was done
# all session, and once it came up reporting itself healthy while unable to read
# 791KB of facts — nothing caught that but a person asking how many it could
# see. So the gate here is not "does it answer", it is "can it still read what
# it had", and the previous image stays tagged so a bad one is one command back.
# Ship a cluster onto the current image.
#
# `ship` used to rsync this tree to 209.50.60.180 and build there, and
# `rollback` retagged an image on the same host. That server was deleted when
# clusters became things the console makes, so both pointed at nothing — and
# neither would have failed loudly, because ssh to a dead address hangs. A
# recipe that cannot work is worse than an absent one: somebody reaches for it
# in a hurry.
#
# What replaces them is not written yet (bla-a1b3): a cluster pulls the image CI
# publishes, and the control plane tells it when. The fact-count gate the old
# `ship` carried was a good idea and belongs in whatever does.
ship:
    @echo "there is no ship. clusters are opened from the console and upgraded"
    @echo "by the control plane — see bla-a1b3. CI publishes the image:"
    @echo "  ghcr.io/shinyobjectz/blazie:latest"
    @exit 1

# Regenerate the README banner from the running site, so it cannot drift from
# the hero it is meant to look like. Needs `just web` running on :3111.
banner:
    @echo "open http://localhost:3111/banner at 1200x420 and capture to priv/static/brand/banner.png"
    @echo "the page is web/app/banner/page.tsx — it renders the same shader and the same wordmark"

# Set one control plane secret in BOTH environments, from stdin.
#
# Eight of them, set twice, by remembering to. They diverged once already and
# the symptom was `/api/me` reporting sign-in unavailable with nothing saying
# why — preview had the github secret and production did not, or the other way
# round, and nothing compares them.
#
#     printf '%s' "$VALUE" | just secret GITHUB_CLIENT_SECRET
#
# Piped rather than passed as an argument, so the value never reaches a shell
# history or a process list.
secret NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    value=$(cat)
    [ -n "$value" ] || { echo "nothing on stdin — pipe the value in"; exit 1; }
    cd web
    for env in "" "--env preview"; do
      printf '%s' "$value" \
        | CLOUDFLARE_ACCOUNT_ID={{ CF_ACCOUNT }} npx wrangler pages secret put {{ NAME }} \
            --project-name blazie $env >/dev/null
    done
    echo "{{ NAME }} set in production and preview"

# What the control plane is missing, in both environments.
#
# A list rather than a diff, because wrangler will not show a value and the
# useful question is not "are they the same" but "is anything absent".
secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    cd web
    for env in "production" "preview"; do
      echo "== $env =="
      flag=""; [ "$env" = "preview" ] && flag="--env preview"
      have=$(CLOUDFLARE_ACCOUNT_ID={{ CF_ACCOUNT }} npx wrangler pages secret list \
               --project-name blazie $flag 2>/dev/null | grep -oE "^  - [A-Z_]+" | tr -d " -")
      for want in GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET UPCLOUD_TOKEN \
                  CLOUDFLARE_API_TOKEN CLOUDFLARE_DNS_TOKEN CLOUDFLARE_ACCOUNT_ID \
                  CLOUDFLARE_ZONE_ID CLUSTER_ZONE BACKUP_BUCKET BACKUP_ENDPOINT \
                  BACKUP_ACCESS_KEY_ID BACKUP_SECRET_ACCESS_KEY; do
        echo "$have" | grep -qx "$want" && echo "  ok      $want" || echo "  MISSING $want"
      done
    done

# The console, in development.
web:
    cd web && pnpm dev --port 3111

# Build the console for a static host.
web-build:
    cd web && pnpm build

# Ship the console to Cloudflare Pages. The account id is explicit because
# this wrangler login can see two accounts and picking the wrong one is silent.
# The output directory and the KV binding are in web/wrangler.jsonc now, so
# there is no directory argument — passing one would deploy the pages without
# the control plane beside them, which looks identical until you sign in.
web-deploy: web-build
    cd web && CLOUDFLARE_ACCOUNT_ID=6d4b74aeb10f455fbf88141901e7595d \
      npx wrangler pages deploy --project-name blazie --branch main --commit-dirty=true
