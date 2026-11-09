#!/bin/bash
# UI utilities for T.R.I.S.T.A.N. scripts
# Usage: source scripts/ui.sh

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Print a header for the script
ui_header() {
    local title="$1"
    echo -e "\n${BOLD}${CYAN}T.R.I.S.T.A.N.${NC} ${BOLD}${title}${NC}\n"
}

# Print a step indicator
ui_step() {
    local step_num="$1"
    local step_name="$2"
    echo -e "${BOLD}${BLUE}→${NC} ${BOLD}${step_name}${NC}"
}

# Print a success message
ui_success() {
    echo -e "${GREEN}✓${NC} $*"
}

# Print an error message
ui_error() {
    echo -e "${RED}✗${NC} $*" >&2
}

# Print a warning message
ui_warn() {
    echo -e "${YELLOW}⚠${NC} $*"
}

# Print info message
ui_info() {
    echo -e "${CYAN}ℹ${NC} $*"
}

# Print a divider
ui_divider() {
    echo -e "${CYAN}────────────────────────────────────────${NC}"
}

# Print footer with summary
ui_footer() {
    echo -e "\n${BOLD}${CYAN}✨ Done!${NC}\n"
}
