#!/bin/bash
# Removes T.R.I.S.T.A.N. from this Mac, so test versions do not pile up. Shows what it will remove and asks first.
#   scripts/uninstall.sh              quit the app and remove installed copies (/Applications, ~/Applications and any other
#                                     copy Spotlight finds) and mounted disk images. Keeps your settings and history.
#   scripts/uninstall.sh --purge      also remove settings, history, caches, saved window state, the pairing secret and
#                                     API keys in the Keychain, and leftovers from the test suite
#   scripts/uninstall.sh --build      also remove build output in this checkout (Tristan.app, dist/, ios/build)
#   scripts/uninstall.sh --dry-run    only list what would be removed
#   scripts/uninstall.sh --yes        do not ask
# Flags can be combined, for example: scripts/uninstall.sh --purge --build --yes
# Not touched: Ollama and its models (a separate tool), voices, and this source checkout itself.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/ui.sh

ui_header "Uninstall"
PURGE=0; BUILD=0; DRY=0; YES=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    --build) BUILD=1 ;;
    --dry-run) DRY=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 2 ;;
  esac
done

BUNDLE_ID="com.tristan.app"
REPO="$(pwd -P)"
LIB="$HOME/Library"

# An app copy is only removed when it really is this app, so a similarly named folder is never deleted by mistake.
is_tristan_app() {
  [ -d "$1" ] && [ "$(basename "$1")" = "Tristan.app" ] &&
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ]
}

APPS=()
add_app() { is_tristan_app "$1" || return 0; local p; p="$(cd "$1" && pwd -P)"; case "$p" in "$REPO"/*) return 0 ;; esac
  for known in ${APPS[@]+"${APPS[@]}"}; do [ "$known" = "$p" ] && return 0; done; APPS+=("$p"); }
add_app "/Applications/Tristan.app"
add_app "$HOME/Applications/Tristan.app"
while IFS= read -r found; do add_app "$found"; done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null)

VOLUMES=()
for v in /Volumes/Tristan*; do [ -d "$v" ] && VOLUMES+=("$v"); done

BUILD_PATHS=()
if [ "$BUILD" = 1 ]; then
  for p in "$REPO/Tristan.app" "$REPO/dist" "$REPO/ios/build"; do [ -e "$p" ] && BUILD_PATHS+=("$p"); done
fi

DATA=()
KEYCHAIN=0
if [ "$PURGE" = 1 ]; then
  for p in "$LIB/Application Support/Tristan" "$LIB/Caches/$BUNDLE_ID" "$LIB/Caches/Tristan" \
           "$LIB/Saved Application State/$BUNDLE_ID.savedState" "$LIB/HTTPStorages/$BUNDLE_ID" \
           "$LIB/Preferences/$BUNDLE_ID.plist" "$LIB/Preferences/Tristan.plist"; do
    [ -e "$p" ] && DATA+=("$p")
  done
  for p in "$LIB"/Preferences/tristan-*-tests-*.plist; do [ -e "$p" ] && DATA+=("$p"); done
  security find-generic-password -s "$BUNDLE_ID" >/dev/null 2>&1 && KEYCHAIN=1
fi

RUNNING=0
pgrep -x Tristan >/dev/null 2>&1 && RUNNING=1

ui_step 1 "Analyzing system"
echo
[ "$RUNNING" = 1 ] && ui_info "Running app will be quit"
[ ${#APPS[@]} -gt 0 ] && { echo "$(ui_info 'App copies:')"; printf '  %s\n' "${APPS[@]}"; }
[ ${#VOLUMES[@]} -gt 0 ] && { echo "$(ui_info 'Mounted disk images (will be ejected):')"; printf '  %s\n' "${VOLUMES[@]}"; }
[ ${#BUILD_PATHS[@]} -gt 0 ] && { echo "$(ui_info 'Build output in this checkout:')"; printf '  %s\n' "${BUILD_PATHS[@]}"; }
if [ "$PURGE" = 1 ]; then
  [ ${#DATA[@]} -gt 0 ] && { echo "$(ui_info 'Settings, history and caches (${#DATA[@]} items):')"; printf '  %s\n' "${DATA[@]}" | head -6; [ ${#DATA[@]} -gt 6 ] && echo "  ... and $(( ${#DATA[@]} - 6 )) more"; }
  [ "$KEYCHAIN" = 1 ] && ui_info "Keychain entries for service $BUNDLE_ID (pairing secret, API keys)"
fi
if [ "$RUNNING" = 0 ] && [ ${#APPS[@]} -eq 0 ] && [ ${#VOLUMES[@]} -eq 0 ] && [ ${#BUILD_PATHS[@]} -eq 0 ] && [ ${#DATA[@]} -eq 0 ] && [ "$KEYCHAIN" = 0 ]; then
  ui_info "Nothing to remove"; [ "$PURGE" = 0 ] && ui_info "(Settings and history are kept unless you pass --purge)"; exit 0
fi
[ "$PURGE" = 0 ] && echo && ui_info "Settings and history are kept (add --purge to remove them too)"
[ "$DRY" = 1 ] && exit 0

if [ "$YES" = 0 ]; then
  echo; printf "${BOLD}Remove these?${NC} [y/N] "; read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) ui_warn "Cancelled"; exit 1 ;; esac
fi

ui_step 2 "Removing files"
echo
if [ "$RUNNING" = 1 ]; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1; pkill -x Tristan >/dev/null 2>&1 || true; sleep 1
  ui_success "Quit the app"
fi
for v in ${VOLUMES[@]+"${VOLUMES[@]}"}; do hdiutil detach "$v" -quiet >/dev/null 2>&1 && ui_success "Ejected $v" || ui_error "Could not eject $v (close anything using it)"; done
for a in ${APPS[@]+"${APPS[@]}"}; do rm -rf "$a" && ui_success "Removed $a" || ui_error "Could not remove $a"; done
for p in ${BUILD_PATHS[@]+"${BUILD_PATHS[@]}"}; do rm -rf "$p" && ui_success "Removed $p"; done
if [ "$PURGE" = 1 ]; then
  # Clear the preference domains through cfprefsd first, or it can write the cached values back.
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  defaults delete Tristan >/dev/null 2>&1 || true
  for p in ${DATA[@]+"${DATA[@]}"}; do rm -rf "$p"; done
  [ ${#DATA[@]} -gt 0 ] && ui_success "Removed ${#DATA[@]} settings, history and cache items"
  n=0; while security delete-generic-password -s "$BUNDLE_ID" >/dev/null 2>&1; do n=$((n+1)); done
  [ "$n" -gt 0 ] && ui_success "Removed $n Keychain entries"
fi

ui_success "If you had LAUNCH AT LOGIN on, also remove T.R.I.S.T.A.N. under System Settings > General > Login Items"
ui_success "Ollama and its models are separate and were left alone (ollama rm <model> removes a model)"
ui_footer
