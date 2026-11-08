#!/usr/bin/env python3
"""Manual benchmark for local models on Ollama (issue #86). Not part of CI and never run by a test.

  python3 scripts/bench-ollama.py MODEL [MODEL ...] [--runs N] [--json FILE]

Needs a running Ollama server on this Mac and the models already pulled (ollama pull MODEL). It sends the same short
tasks to each model through /api/chat and scores them by rule, so a second person gets the same questions. It measures
speed and memory too. It does not run commands for the model: tool calls are only parsed and checked.

Tasks (what T.R.I.S.T.A.N. asks of a model):
  tool_read    must answer with a read_file tool call whose arguments are valid JSON with a path
  tool_edit    must start a small edit correctly: a read_file call for src/app.py, or an edit_file call (path, old_text, new_text)
  tool_run     must answer with a run_command tool call with a non-empty command (the command is never run)
  no_tool      a plain question: must answer in text and must not call a tool
  spoken_line  one short spoken status line, no Markdown, at most 25 words
  code         write a small function; its code is checked against asserts in a throwaway python3 process
  context      find one fact in about 8,000 to 10,500 tokens of filler (long context). It needs Ollama to use a context of
               at least that size; the script does not set num_ctx, so a small default makes this task fail.
"""
import argparse, ast, json, re, subprocess, sys, tempfile, urllib.request

HOST = "http://localhost:11434"
OPTIONS = {"temperature": 0, "seed": 1, "num_predict": 2048}

def tool(name, desc, props, required):
    return {"type": "function", "function": {"name": name, "description": desc,
            "parameters": {"type": "object", "properties": {k: {"type": "string"} for k in props}, "required": required}}}

READ = tool("read_file", "Read a text file and return its contents", ["path"], ["path"])
EDIT = tool("edit_file", "Replace one piece of text in a file", ["path", "old_text", "new_text"], ["path", "old_text", "new_text"])
RUN = tool("run_command", "Run a shell command in the project folder", ["command"], ["command"])
SYSTEM = ("You are a coding agent in a project folder. Use the tools to look at and change files. "
          "Call a tool when you need one. Do not explain before calling it.")

def post(path, body, timeout=900):
    request = urllib.request.Request(HOST + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)

def chat(model, user, tools=None, system=SYSTEM):
    body = {"model": model, "stream": False, "options": OPTIONS,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    if tools:
        body["tools"] = tools
    return post("/api/chat", body)

def calls(reply):
    out = []
    for call in reply["message"].get("tool_calls") or []:
        arguments = call["function"].get("arguments")
        if isinstance(arguments, str):
            try: arguments = json.loads(arguments)
            except ValueError: arguments = None
        out.append((call["function"]["name"], arguments))
    return out

def one_call(reply, name, keys):
    found = calls(reply)
    return len(found) == 1 and found[0][0] == name and isinstance(found[0][1], dict) and all(found[0][1].get(k) for k in keys)

FILLER = " ".join(f"Line {i}: the quick brown fox number {i} jumps over lazy dog number {i * 7}." for i in range(1, 420))
SECRET = "The release codeword is TANGERINE-4417."

def task_context(model):
    middle = len(FILLER) // 2
    text = FILLER[:middle] + " " + SECRET + " " + FILLER[middle:]
    reply = chat(model, text + "\n\nWhat is the release codeword? Answer with the codeword only.", system="Answer from the text.")
    return "TANGERINE-4417" in reply["message"]["content"], reply

BANNED_CALLS = {"open", "exec", "eval", "compile", "input", "__import__", "getattr", "setattr", "delattr", "globals", "locals", "vars", "breakpoint"}

def safe_code(code):
    """True when the code parses and only imports `re`, calls none of BANNED_CALLS and touches no dunder attribute."""
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return False
    for node in ast.walk(tree):
        if isinstance(node, ast.Import) and any(alias.name != "re" for alias in node.names):
            return False
        if isinstance(node, ast.ImportFrom) and node.module != "re":
            return False
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in BANNED_CALLS:
            return False
        if isinstance(node, ast.Attribute) and node.attr.startswith("__"):
            return False
    return True

def task_code(model):
    reply = chat(model, "Write a Python function is_palindrome(text) that ignores case and non-letters. "
                 "Reply with one python code block and nothing else.", system="You write short Python.")
    block = re.search(r"```(?:python)?\n(.*?)```", reply["message"]["content"], re.S)
    code = block.group(1) if block else ""
    if not safe_code(code):
        return False, reply  # a tiny pure function needs nothing but `re`; never run anything else
    checks = "assert is_palindrome('A man, a plan, a canal: Panama')\nassert not is_palindrome('hello')\nassert is_palindrome('')\n"
    with tempfile.TemporaryDirectory() as folder:
        try:
            done = subprocess.run([sys.executable, "-I", "-c", code + "\n" + checks], cwd=folder, timeout=10, capture_output=True)
            return done.returncode == 0, reply
        except subprocess.TimeoutExpired:
            return False, reply

def task_spoken(model):
    reply = chat(model, "Say one short spoken status line for the user: the tests passed and one file changed. "
                 "Plain words, no Markdown, no lists, at most 25 words.", system="You speak aloud in short plain lines.")
    text = reply["message"]["content"].strip()
    return 0 < len(text.split()) <= 25 and not re.search(r"[*#`_>\[\]]|^\s*(?:-|\d+[.)])\s", text, re.M), reply

TASKS = [
    ("tool_read", lambda m: (lambda r: (one_call(r, "read_file", ["path"]), r))(chat(m, "Show me what is in README.md", [READ, EDIT, RUN]))),
    ("tool_edit", lambda m: (lambda r: (one_call(r, "edit_file", ["path", "old_text", "new_text"]) or
                                        (one_call(r, "read_file", ["path"]) and "app.py" in str(calls(r)[0][1]["path"])), r))(
        chat(m, "In src/app.py change the text 'Hello' to 'Hi'.", [READ, EDIT, RUN]))),
    ("tool_run", lambda m: (lambda r: (one_call(r, "run_command", ["command"]), r))(chat(m, "List the files in this folder with a command.", [READ, EDIT, RUN]))),
    ("no_tool", lambda m: (lambda r: (not calls(r) and len(r["message"]["content"].split()) > 2, r))(chat(m, "In one sentence, what is a git branch?", [READ, EDIT, RUN]))),
    ("spoken_line", task_spoken),
    ("code", task_code),
    ("context", task_context),
]

def memory(model):
    """Size of the loaded model in GB (all, and the part in GPU memory), from /api/ps."""
    try:
        with urllib.request.urlopen(HOST + "/api/ps", timeout=10) as response:
            for entry in json.load(response)["models"]:
                if entry["name"] == model or entry["name"] == model + ":latest":
                    return round(entry["size"] / 1e9, 1), round(entry.get("size_vram", 0) / 1e9, 1)
    except Exception:
        pass
    return None, None

def median(values):
    values = sorted(values)
    return values[len(values) // 2] if values else None

def run(model, runs, only=None):
    chat(model, "Say ok.")  # load the model first so the timings below are warm
    results = {"model": model, "tasks": {}}
    speeds, first_token = [], []
    for name, task in TASKS:
        if only and name not in only:
            continue
        passes = 0
        for _ in range(runs):
            try:
                ok, reply = task(model)
            except Exception as error:  # a timeout or an HTTP error counts as a failed run, and the others still run
                print(f"  {name:12} run failed: {error}", file=sys.stderr, flush=True)
                continue
            passes += 1 if ok else 0
            if reply.get("eval_duration"):
                speeds.append(reply["eval_count"] / (reply["eval_duration"] / 1e9))
            if name == "context":
                results["context_prompt_tokens"] = reply.get("prompt_eval_count")
                results["context_seconds"] = round(reply.get("prompt_eval_duration", 0) / 1e9, 1)
            elif reply.get("prompt_eval_duration") is not None:
                first_token.append(reply["prompt_eval_duration"] / 1e9)
        results["tasks"][name] = f"{passes}/{runs}"
        print(f"  {name:12} {passes}/{runs}", flush=True)
    results["tokens_per_second"] = round(median(speeds), 1) if speeds else None
    results["prompt_seconds_median"] = round(median(first_token), 2) if first_token else None
    results["memory_gb"], results["gpu_memory_gb"] = memory(model)
    return results

def main():
    parser = argparse.ArgumentParser(description="Benchmark Ollama models for T.R.I.S.T.A.N.")
    parser.add_argument("models", nargs="+")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--json")
    parser.add_argument("--only", help="comma-separated task names to run (default: all)")
    args = parser.parse_args()
    known = [name for name, _ in TASKS]
    if args.only and not set(args.only.split(",")) <= set(known):
        sys.exit("Unknown task in --only. Tasks: " + ", ".join(known))
    try:
        json.load(urllib.request.urlopen(HOST + "/api/tags", timeout=3))
    except Exception:
        sys.exit("Ollama is not running on " + HOST + ". Start it with: ollama serve")
    out = []
    for model in args.models:
        print(model, flush=True)
        try:
            out.append(run(model, args.runs, args.only.split(",") if args.only else None))
        except Exception as error:  # for example a model that is not pulled: report it and go on to the next
            print(f"  {model} skipped: {error}", file=sys.stderr, flush=True)
            out.append({"model": model, "error": str(error)})
    if args.json:
        with open(args.json, "w") as handle:
            json.dump(out, handle, indent=2)
    print(json.dumps(out, indent=2))

if __name__ == "__main__":
    main()
