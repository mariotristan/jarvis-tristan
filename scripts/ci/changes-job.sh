#!/bin/bash
# The `changes-ci` and `changes-windows` jobs: works out which files this run brings and writes mac=, ios= and
# windows= to $GITHUB_OUTPUT (scripts/ci/changed-paths.sh decides). The jobs that build run unless their flag is
# exactly `false`.
#
# Fail safe: whenever the answer is not certain (the classifier's self-test fails, an event other than push or
# pull_request, a commit that is not what we expect, git fails, no changed files) every flag is true. This script
# always exits 0, so the job reports; a broken self-test also leaves a visible ::error:: annotation.
#
# Needs a checkout with fetch-depth 2, and EVENT (github.event_name) and BEFORE (github.event.before) set.
#
#   pull_request  HEAD is the merge commit GitHub made of the PR into the base branch: HEAD^1 is the base tip and
#                 HEAD^2 the PR head, so `git diff HEAD^1 HEAD` is exactly what the PR brings over the base.
#   push          `git diff HEAD^1 HEAD` only when the push added one commit on top of BEFORE (a squash merge, or a
#                 merge commit whose first parent is the old tip). A push of several commits (a rebase merge) runs
#                 everything, because HEAD^1 would show only the last of them.
set -u
here=$(cd "$(dirname "$0")" && pwd)
event=${EVENT:-}
before=${BEFORE:-}
out=${GITHUB_OUTPUT:-/dev/stdout}

flags=""
reason=""

everything() { # everything <reason>
    flags=$'mac=true\nios=true\nwindows=true'
    reason=$1
}

if ! /bin/bash "$here/test-changed-paths.sh"; then
    echo "::error title=Path classifier::scripts/ci/test-changed-paths.sh failed; running every job."
    everything "the classifier's self-test failed"
else
    parents=$(git rev-list --parents -n 1 HEAD 2>/dev/null | wc -w | tr -d ' ')
    base=""
    case $event in
        pull_request)
            if [ "$parents" = 3 ]; then base=HEAD^1
            else everything "pull_request but HEAD is not a merge commit (it has $((parents - 1)) parents)"; fi ;;
        push)
            first=$(git rev-parse --verify --quiet HEAD^1 2>/dev/null || true)
            if [ -n "$first" ] && [ "$first" = "$before" ]; then base=HEAD^1
            else everything "push of more than one commit, or a new branch (before=${before:-none})"; fi ;;
        *)
            everything "event '${event:-none}' is not push or pull_request" ;;
    esac

    if [ -n "$base" ]; then
        if changed=$(git -c core.quotePath=false diff --no-renames --name-only "$base" HEAD); then
            if [ -z "$changed" ]; then
                everything "no changed files"
            else
                echo "Changed files ($(printf '%s\n' "$changed" | wc -l | tr -d ' ')):"
                printf '%s\n' "$changed" | sed 's/^/  /'
                if flags=$(printf '%s\n' "$changed" | /bin/bash "$here/changed-paths.sh"); then
                    reason="classified the changed files"
                else
                    everything "changed-paths.sh failed"
                fi
            fi
        else
            everything "git diff failed"
        fi
    fi
fi

# The classifier prints exactly three lines; anything else runs everything.
valid=$(printf '%s\n' "$flags" | grep -cEx 'mac=(true|false)|ios=(true|false)|windows=(true|false)')
lines=$(printf '%s\n' "$flags" | wc -l | tr -d ' ')
if [ "$valid" != 3 ] || [ "$lines" != 3 ]; then
    everything "unexpected classifier output"
fi

echo "Flags ($reason):"
printf '%s\n' "$flags"
printf '%s\n' "$flags" >> "$out"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo "### Changed paths"; echo; echo "$reason"; echo; echo '```'; printf '%s\n' "$flags"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi
exit 0
