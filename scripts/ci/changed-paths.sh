#!/bin/bash
# Decides which CI jobs a change needs, from the list of changed files.
#
#   scripts/ci/changed-paths.sh [file]     paths one per line, from the file or stdin
#
# Prints three lines, for example:
#   mac=true
#   ios=false
#   windows=false
#
#   mac      ci.yml `build-and-test`: `swift test` (every target in Package.swift, including TristanCoreTests and
#            TristanCLITests), then scripts/make-dmg.sh (which runs scripts/bundle.sh)
#   ios      ci.yml `ios`: the Xcode project in ios/, which compiles Sources/TristanCore (without Processes/) and
#            Sources/Tristan/Shared by path (ios/project.yml), not through Package.swift
#   windows  windows.yml `windows`: TristanCore, TristanCLICore and TristanCLI with their tests, the PowerShell
#            scripts, the fakes in scripts/ci, the zip and the installer
#
# Each path takes the first rule below that matches it; the answer is the union over all paths. Conservative on
# purpose: a path no rule matches, or an empty list, runs everything. Patterns are bash `case` globs matched against
# the whole path: `*` also matches `/` (so `docs/*` is the whole docs tree), and a pattern without a `/` only
# matches a file at the top of the repository (so `*.md` is README.md, not Sources/x/notes.md).
#
# Runs on bash 3.2 (macOS) and bash 5 (ubuntu-latest). Test: scripts/ci/test-changed-paths.sh
#
# pattern                                 jobs                why
RULES='
scripts/ci/changed-paths.sh               mac,ios,windows     the classifier itself: a change to it runs everything
scripts/ci/test-changed-paths.sh          mac,ios,windows     the same
scripts/ci/changes-job.sh                 mac,ios,windows     the same
docs/*                                    -                   the Pages site and notes; nothing builds or reads them
*.md                                      -                   README.md and other top-level Markdown
.gitignore                                -                   only untracked files; never changes a checkout
LICENSE                                   windows             copied into the Windows zip and shown by the installer
.github/workflows/ci.yml                  mac,ios             a workflow change runs its own jobs
.github/workflows/windows.yml             windows             the same
.github/workflows/release.yml             windows             runs the same Windows lines as windows.yml on a tag
Package.swift                             mac,ios,windows     every SwiftPM build; listed with the core to be safe
Package.resolved                          mac,ios,windows     the same
VERSION                                   mac,ios,windows     the app version (scripts/bundle.sh)
Sources/TristanCore/*                     mac,ios,windows     the portable core: all three compile it
Sources/TristanCLICore/*                  mac,windows         the tristan command (built and tested by swift test)
Sources/TristanCLI/*                      mac,windows         the same
Sources/Tristan/Shared/*                  mac,ios             the Mac app, and compiled by path into the iOS app
Sources/Tristan/*                         mac                 the Mac app (AppKit, only declared on macOS)
Tests/TristanCoreTests/*                  mac,windows         swift test on the Mac runs every test target
Tests/TristanCLITests/*                   mac,windows         the same
Tests/TristanTests/*                      mac                 the Mac app tests
ios/*                                     ios                 the iOS app; nothing in the Mac build reads ios/
scripts/THIRD-PARTY-NOTICES.windows.txt   windows             packed into the Windows zip
scripts/ci/*                              windows             the Windows job: test-count checker, fakes, mocks, spike
scripts/windows/*                         windows             the Inno Setup script
scripts/*/*                               mac,ios,windows     any other scripts subfolder: unknown, run everything
scripts/*.ps1                             windows             setup-ollama.ps1, package-windows*.ps1
scripts/ios-*.sh                          mac,ios             iOS helpers (manual, but they touch ios/)
scripts/*.sh                              mac                 bundle.sh and make-dmg.sh run in build-and-test; the rest are Mac helpers
scripts/*.swift                           mac                 record-window.swift, a Mac helper
'

set -u
export LC_ALL=C # match bytes, so a path that is not valid UTF-8 cannot trip the glob matcher

mac=false ios=false windows=false
seen=0

add() { # add <jobs>
    case ",$1," in *,mac,*) mac=true ;; esac
    case ",$1," in *,ios,*) ios=true ;; esac
    case ",$1," in *,windows,*) windows=true ;; esac
}

# Prints the jobs of the first rule that matches $1, or mac,ios,windows when none does.
jobs_for() {
    local path=$1 pattern jobs _why
    while read -r pattern jobs _why; do
        [ -n "$pattern" ] || continue
        case $pattern in
            */*) ;;
            *) case $path in */*) continue ;; esac ;;
        esac
        # Unquoted on purpose: the pattern is a glob.
        # shellcheck disable=SC2254
        case $path in
            $pattern) echo "$jobs"; return ;;
        esac
    done <<EOF
$RULES
EOF
    echo "mac,ios,windows"
}

classify() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}          # CRLF input
        while :; do                 # leading ./
            case $line in ./*) line=${line#./} ;; *) break ;; esac
        done
        [ -n "$line" ] || continue
        seen=$((seen + 1))
        add "$(jobs_for "$line")"
    done
}

if [ $# -gt 0 ]; then
    [ -r "$1" ] || { echo "changed-paths.sh: cannot read $1" >&2; exit 2; }
    classify < "$1"
else
    classify
fi

[ "$seen" -gt 0 ] || { mac=true ios=true windows=true; } # no list: run everything

echo "mac=$mac"
echo "ios=$ios"
echo "windows=$windows"
