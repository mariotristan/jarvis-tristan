#!/usr/bin/env bash
# Sets up Ollama for Tristan: installs it if missing, starts the server, pulls a model and checks that it answers.
#   scripts/setup-ollama.sh               pulls a default for this Mac's memory (see below)
#   scripts/setup-ollama.sh qwen2.5-coder pulls another model by name
#   scripts/setup-ollama.sh --start-only  only starts the server if Ollama is installed (no install, no download).
#                                         Tristan runs this when the internet is down. Exit 2 means not installed.
# With no model named, the default depends on memory (measured on one 48 GB Mac, issue #90; docs/local-models.html):
#   40 GB or more  qwen3-coder:30b   28 to 39 GB  gpt-oss:20b   14 to 27 GB  qwen3:8b   less than 14 GB  llama3.1 (nothing measured fits)
set -euo pipefail
source "$(dirname "$0")/ui.sh"

ui_header "Setup Ollama"
START_ONLY=0
if [ "${1:-}" = "--start-only" ]; then START_ONLY=1; shift; fi
MEMORY_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
default_model() {
  if   [ "$MEMORY_GB" -ge 40 ]; then echo "qwen3-coder:30b"
  elif [ "$MEMORY_GB" -ge 28 ]; then echo "gpt-oss:20b"
  elif [ "$MEMORY_GB" -ge 14 ]; then echo "qwen3:8b"
  else echo "llama3.1"; fi
}
MODEL="${1:-$(default_model)}"
# An app launched from the Dock has a short PATH, so look where Ollama usually lives.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/Applications/Ollama.app/Contents/Resources"
HOST="http://localhost:11434"

if ! command -v ollama >/dev/null 2>&1; then
  [ "$START_ONLY" = 1 ] && { ui_error "Ollama is not installed"; exit 2; }
  command -v brew >/dev/null 2>&1 || { ui_error "Ollama is not installed and Homebrew is missing. Install it from https://ollama.com/download"; exit 1; }
  ui_step 1 "Installing Ollama with Homebrew"
  brew install ollama
else
  ui_step 1 "Checking Ollama version"
fi
ui_info "Ollama $(ollama --version 2>&1 | tail -1)"
[ -n "${1:-}" ] || ui_info "No model named: using $MODEL for a Mac with $MEMORY_GB GB of memory (name one to choose another)"

STARTED=""
if ! curl -fsS -m 2 "$HOST/api/tags" >/dev/null 2>&1; then
  ui_step 2 "Starting the Ollama server"
  nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
  STARTED=$!
  for _ in $(seq 1 30); do
    curl -fsS -m 2 "$HOST/api/tags" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS -m 2 "$HOST/api/tags" >/dev/null 2>&1 || { ui_error "The server did not start. See /tmp/ollama-serve.log"; exit 1; }
fi

if [ "$START_ONLY" = 1 ]; then
  ui_success "Ollama is running"
  ui_footer
  exit 0
fi

ui_step 2 "Pulling $MODEL (this can take a few minutes the first time)"
ollama pull "$MODEL"

ui_step 3 "Checking that $MODEL answers"
REPLY=$(curl -fsS -m 300 "$HOST/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi in three words.\"}]}" 2>&1) \
  || { ui_error "The model did not answer: $REPLY"; exit 1; }
printf '   %s\n' "$(printf '%s\n' "$REPLY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip())')"

ui_step 4 "Checking tool support (Tristan needs it to edit files and run commands)"
TOOLS=$(curl -sS -m 300 "$HOST/v1/chat/completions" -H 'Content-Type: application/json' -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"What is in the folder?\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"list_dir\",\"description\":\"List a folder\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}}]}" 2>&1 || true)
if printf '%s' "$TOOLS" | grep -qi 'does not support tools'; then
  ui_warn "$MODEL cannot use tools. It is fine for questions (kids mode) but not for coding. Try: scripts/setup-ollama.sh llama3.1"
else
  ui_success "Tools are supported"
fi

echo
ui_step 5 "Listing installed models"
ollama list
echo
ui_success "In Tristan open Configuration > OLLAMA and pick a model, or leave it blank to use the first installed one"
[ -n "$STARTED" ] && ui_info "The server was started by this script and keeps running in the background (log: /tmp/ollama-serve.log). Stop it with: pkill -f 'ollama serve'"
ui_footer
exit 0
