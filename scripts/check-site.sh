#!/bin/bash
# Checks the website in docs/ against the rules in docs/site-guide.md. Run it before you open a pull request.
#
#   bash scripts/check-site.sh
#   FORBIDDEN='word one|word two' bash scripts/check-site.sh    also fail on any of these words (case-insensitive)
#
# Fails (exit 1) when: the main menu or the footer differs between pages, a page lacks a title, description, canonical
# link, one <h1> or a <main id="main">, a title is not "Name—T.R.I.S.T.A.N.", an <img> has no alt, a local link or
# image points at a file that does not exist, or a FORBIDDEN word appears in docs/, the README or an instruction file.
# Prints a warning (does not fail) for an em dash in body text. Runs on bash 3.2 (macOS) and bash 5.
set -u
cd "$(dirname "$0")/.." || exit 2
fail=0
bad() { echo "FAIL: $*"; fail=1; }

pages=$(ls docs/*.html)
n=$(echo "$pages" | wc -l | tr -d ' ')

# Menu and footer links, in order, must be the same on every guide page. The home page has its own menu (in-page
# anchors), so its footer only has to link every page.
menu_of()   { awk '/<nav aria-label="Main">/{f=1;next} /<\/nav>/{f=0} f' "$1" | grep -o 'href="[^"]*"'; }
footer_of() { awk '/<footer>/{f=1} f' "$1" | grep -o '<a href="[^"]*"' | sed 's/<a //'; }
ref_menu=$(menu_of docs/backlog.html)
ref_footer=$(footer_of docs/backlog.html)
for p in $pages; do
    if [ "$p" = docs/index.html ]; then
        for q in $pages; do
            b=$(basename "$q")
            [ "$b" = index.html ] && continue
            footer_of "$p" | grep -q "href=\"$b\"" || bad "$p: the footer does not link $b"
        done
        continue
    fi
    [ "$(menu_of "$p")" = "$ref_menu" ]     || bad "$p: the main menu differs from docs/backlog.html"
    [ "$(footer_of "$p")" = "$ref_footer" ] || bad "$p: the footer links differ from docs/backlog.html"
done

for p in $pages; do
    base=$(basename "$p")
    grep -q '<meta charset="utf-8">' "$p"            || bad "$p: no charset"
    grep -q 'name="viewport"' "$p"                   || bad "$p: no viewport meta"
    grep -q '<meta name="description" content="[^"]\{20,\}"' "$p" || bad "$p: no description"
    grep -q "rel=\"canonical\" href=\"https://mariotristan.github.io/jarvis-tristan/\($base\)\?\"" "$p" || bad "$p: canonical link is missing or points elsewhere"
    grep -q '<main id="main"' "$p"                   || bad "$p: no <main id=\"main\">"
    [ "$(grep -c '<h1' "$p")" = 1 ]                  || bad "$p: needs exactly one <h1>"
    case $p in docs/index.html) ;; *) grep -q '<title>[^<—]*—T\.R\.I\.S\.T\.A\.N\.</title>' "$p" || bad "$p: the title is not 'Name—T.R.I.S.T.A.N.'" ;; esac
    # an <img> with no alt (single-line tags)
    if grep -o '<img [^>]*>' "$p" | grep -v ' alt=' | grep -q .; then bad "$p: an <img> without alt"; fi
    # a body em dash is a warning: older lines still have them
    body=$(grep -v -e '<title>' -e 'og:title' -e 'og:description' -e 'name="description"' "$p" | grep -c '—')
    [ "$body" = 0 ] || echo "warn: $p has $body line(s) with an em dash in the body (avoid in new text)"
done

# Local links and images exist.
for p in $pages; do
    for t in $(grep -o '\(href\|src\|poster\)="[^"]*"' "$p" | sed 's/^[a-z]*="//; s/"$//' | grep -v -e '^https\?:' -e '^mailto:' -e '^#' -e '^$' -e '^data:'); do
        f=${t%%#*}; f=${f%%\?*}
        [ -e "docs/$f" ] || bad "$p: links to docs/$f, which does not exist"
    done
done

# Optional: words that must not appear anywhere public.
if [ -n "${FORBIDDEN:-}" ]; then
    hits=$(grep -rIil -E "$FORBIDDEN" docs README.md AGENTS.md CLAUDE.md GEMINI.md CONVENTIONS.md .github .cursor .windsurfrules .clinerules .aider.conf.yml 2>/dev/null)
    [ -z "$hits" ] || bad "a FORBIDDEN word appears in: $(echo $hits)"
fi

if [ $fail = 0 ]; then echo "check-site.sh: $n pages OK"; else exit 1; fi
