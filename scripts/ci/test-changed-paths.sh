#!/bin/bash
# Self-test for scripts/ci/changed-paths.sh. Exits non-zero, naming each case that fails.
#
#   /bin/bash scripts/ci/test-changed-paths.sh
#
# Each case: the jobs that must run ("none" for none), then the changed paths, one per argument. Runs on bash 3.2
# (macOS) and bash 5 (ubuntu-latest); the `changes-*` jobs run it before they trust the classifier.
set -u
here=$(cd "$(dirname "$0")" && pwd)
classifier="$here/changed-paths.sh"
cases=0
failures=0

expect() { # expect <jobs> <stdin text> <label>
    local want_mac=false want_ios=false want_windows=false want got
    case " $1 " in *" mac "*) want_mac=true ;; esac
    case " $1 " in *" ios "*) want_ios=true ;; esac
    case " $1 " in *" windows "*) want_windows=true ;; esac
    want=$(printf 'mac=%s\nios=%s\nwindows=%s' "$want_mac" "$want_ios" "$want_windows")
    got=$(printf '%s' "$2" | /bin/bash "$classifier" 2>&1)
    cases=$((cases + 1))
    if [ "$got" != "$want" ]; then
        failures=$((failures + 1))
        echo "FAIL: $3"
        echo "  input:    $(printf '%s' "$2" | tr '\n\r' '|~')"
        echo "  expected: $(printf "%s" "$want" | tr "\n" " ")"
        echo "  got:      $(printf "%s" "$got" | tr "\n" " ")"
    fi
}

# case <jobs> <path>...   paths joined with newlines
case_() {
    local jobs=$1 input="" p
    shift
    for p in "$@"; do input="$input$p"$'\n'; done
    expect "$jobs" "$input" "$jobs <= $*"
}

# Documentation: nothing runs.
case_ none        docs/ci-and-release.md
case_ none        docs/superpowers/specs/2026-11-06-windows-spike-notes.md
case_ none        docs/index.html docs/windows.html docs/assets/x.png
case_ none        README.md
case_ none        docs/windows.html README.md
case_ none        .gitignore
case_ none        CONTRIBUTING.md
# A pattern without / only matches at the top: Markdown inside a source folder is not documentation.
case_ "mac"       Sources/Tristan/notes.md
case_ "mac ios windows" Sources/TristanCore/README.md
case_ "mac"       docs/ci-and-release.md Sources/Tristan/Providers.swift

# The Swift targets.
case_ "mac"       Sources/Tristan/Providers.swift
case_ "mac ios"   Sources/Tristan/Shared/Theme.swift
case_ "mac ios windows" Sources/TristanCore/AgentLoop.swift
case_ "mac ios windows" Sources/TristanCore/Processes/ProcessLauncher.swift
case_ "mac windows" Sources/TristanCLICore/RunCommand.swift
case_ "mac windows" Sources/TristanCLI/main.swift
case_ "mac"       Tests/TristanTests/ThemeTests.swift
case_ "mac windows" Tests/TristanCLITests/x.swift
case_ "mac windows" Tests/TristanCoreTests/AgentLoopTests.swift
case_ "mac ios windows" Sources/TristanNew/x.swift
case_ "mac ios windows" Tests/TristanNewTests/x.swift
case_ "mac ios windows" Package.swift
case_ "mac ios windows" Package.resolved
case_ "mac ios windows" VERSION
case_ "windows"   LICENSE

# iOS.
case_ "ios"       ios/project.yml
case_ "ios"       ios/TristanIOS.xcodeproj/project.pbxproj ios/App/ContentView.swift

# Scripts.
case_ "windows"   scripts/ci/check-test-count.ps1
case_ "windows"   scripts/ci/fakes/node_modules/fake-claude/cli.js
case_ "windows"   scripts/ci/fakes/.gitattributes
case_ "windows"   scripts/ci/spike/Sources/launch/main.swift
case_ "windows"   scripts/package-windows.ps1
case_ "windows"   scripts/setup-ollama.ps1
case_ "windows"   scripts/windows/tristan.iss
case_ "windows"   scripts/THIRD-PARTY-NOTICES.windows.txt
case_ "mac"       scripts/make-dmg.sh
case_ "mac"       scripts/bundle.sh scripts/setup-ollama.sh
case_ "mac"       scripts/record-window.swift
case_ "mac ios"   scripts/ios-icon.sh
case_ "mac ios windows" scripts/newtool/run.sh
case_ "mac ios windows" scripts/ci/changed-paths.sh
case_ "mac ios windows" scripts/ci/test-changed-paths.sh
case_ "mac ios windows" scripts/ci/changes-job.sh

# Workflows.
case_ "windows"   .github/workflows/windows.yml
case_ "windows"   .github/workflows/release.yml
case_ "mac ios"   .github/workflows/ci.yml
case_ "mac ios windows" .github/workflows/secret-scan.yml
case_ "mac ios windows" .github/dependabot.yml
case_ "mac ios windows" .gitattributes

# Unknown files run everything; the answer is the union over all files.
case_ "mac ios windows" tools/foo.py
case_ "mac ios windows" docs/index.html tools/foo.py
case_ "mac windows" Sources/Tristan/Providers.swift scripts/package-windows.ps1 README.md
case_ "mac ios windows" Sources/Tristan/Shared/Theme.swift scripts/windows/tristan.iss
case_ "mac ios windows" .github/workflows/ci.yml .github/workflows/windows.yml scripts/ci/check-test-count.ps1

# Input shapes: empty input runs everything, as do blank lines only.
expect "mac ios windows" ""                "empty input"
expect "mac ios windows" $'\n\n'           "blank lines only"
expect "mac"     $'Sources/Tristan/Providers.swift\r\nREADME.md\r\n' "CRLF lines"
expect "none"    $'docs/a.md\r\n'          "CRLF docs line"
expect "mac ios" "./Sources/Tristan/Shared/Theme.swift"$'\n' "leading ./"
expect "none"    "././README.md"           "leading ././ and no final newline"
expect "none"    $'docs/My Notes/a b.md\n' "a path with spaces"
expect "mac"     $'Sources/Tristan/Café Théâtre.swift\n' "a non-ASCII path"
expect "none"    $'docs/\xe9t\xe9.md\n'    "a path that is not UTF-8"
expect "mac ios windows" $'"docs/caf\\303\\251.md"\n' "a git-quoted path (core.quotePath) is unknown: everything"
expect "mac ios windows" $'README.md\nfoo\n' "a top-level unknown file"

# The file argument gives the same answer as stdin.
tmp=$(mktemp "${TMPDIR:-/tmp}/changed-paths.XXXXXX")
printf '%s\n' Sources/Tristan/Shared/Theme.swift docs/index.html > "$tmp"
got=$(/bin/bash "$classifier" "$tmp")
rm -f "$tmp"
cases=$((cases + 1))
if [ "$got" != $'mac=true\nios=true\nwindows=false' ]; then
    failures=$((failures + 1)); echo "FAIL: file argument: got $(printf "%s" "$got" | tr "\n" " ")"
fi

if [ "$failures" -gt 0 ]; then
    echo "test-changed-paths.sh: $failures of $cases cases failed" >&2
    exit 1
fi
echo "test-changed-paths.sh: all $cases cases passed"
