#!/usr/bin/env bash
# Sets up Ollama for Tristan: installs it if missing, starts the server, pulls a model and checks that it answers.
#   scripts/setup-ollama.sh               pulls llama3.1 (good all-round, handles tools)
#   scripts/setup-ollama.sh qwen2.5-coder pulls another model by name
set -euo pipefail

MODEL="${1:-llama3.1}"
HOST="http://localhost:11434"

say() { printf '\033[36m==>\033[0m %s\n' "$1"; }
die() { printf '\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }

if ! command -v ollama >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "Ollama is not installed and Homebrew is missing. Install it from https://ollama.com/download and run this again."
  say "Installing Ollama with Homebrew"
  brew install ollama
fi
say "Ollama $(ollama --version 2>&1 | tail -1)"

STARTED=""
if ! curl -fsS -m 2 "$HOST/api/tags" >/dev/null 2>&1; then
  say "Starting the Ollama server"
  nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
  STARTED=$!
  for _ in $(seq 1 30); do
    curl -fsS -m 2 "$HOST/api/tags" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS -m 2 "$HOST/api/tags" >/dev/null 2>&1 || die "The server did not start. See /tmp/ollama-serve.log"
fi

say "Pulling $MODEL (this can take a few minutes the first time)"
ollama pull "$MODEL"

say "Checking that $MODEL answers"
REPLY=$(curl -fsS -m 300 "$HOST/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi in three words.\"}]}" 2>&1) \
  || die "The model did not answer: $REPLY"
printf '%s\n' "$REPLY" | python3 -c 'import json,sys; print("   ", json.load(sys.stdin)["choices"][0]["message"]["content"].strip())'

say "Checking tool support (Tristan needs it to edit files and run commands)"
TOOLS=$(curl -sS -m 300 "$HOST/v1/chat/completions" -H 'Content-Type: application/json' -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"What is in the folder?\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"list_dir\",\"description\":\"List a folder\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}}]}" 2>&1 || true)
if printf '%s' "$TOOLS" | grep -qi 'does not support tools'; then
  printf '\033[33mWarning:\033[0m %s cannot use tools. It is fine for questions (kids mode) but not for coding. Try: scripts/setup-ollama.sh llama3.1\n' "$MODEL"
else
  say "Tools are supported"
fi

echo
say "Installed models:"
ollama list
echo
say "Done. In Tristan open Configuration > OLLAMA and pick a model, or leave it blank to use the first installed one."
[ -n "$STARTED" ] && say "The server was started by this script and keeps running in the background (log: /tmp/ollama-serve.log). Stop it with: pkill -f 'ollama serve'"
exit 0
