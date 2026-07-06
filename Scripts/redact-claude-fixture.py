#!/usr/bin/env python3
"""Redact a Claude Code JSONL transcript (or a single-object meta.json) into
a structure-true, content-scrubbed fixture.

Walks every JSON value in the file and:
  (a) replaces string VALUES longer than 40 chars with a deterministic
      "[redacted-<n>-chars-<len>]" marker, except values of allowlisted
      keys (ids, types, timestamps, etc. — never prose);
  (b) overwrites "cwd" / "gitBranch" values with fixed placeholders;
  (c) drops lines whose top-level "type" is not in KEPT_TYPES (only
      applies to objects that have a "type" key at all, so single-object
      meta.json files — which have no "type" — pass through);
  (d) truncates string fields under a tool_use block's "input" to 60
      chars (plus the same marker for the remainder) instead of fully
      redacting them, so tool calls stay legible.

Deterministic: the marker's <n> is an incrementing counter over the
redactions applied in file order, so a given input always produces
identical output.

Usage: redact-claude-fixture.py <input.jsonl> <output.jsonl>
"""
import json
import re
import sys

# Belt-and-suspenders scrub applied to the fully-serialized line, independent
# of the structural (a)-(d) rules above: catches these exact substrings no
# matter which field they came from (e.g. "@Observable" in a truncated Bash
# snippet, or "sk-" inside the unrelated word "task-notification"). The
# fixture-writer's privacy contract requires a hard zero-match grep for
# these patterns, so this pass is unconditional rather than key-aware.
#
# Applied in order to the same string, so entries earlier in this list run
# first — the generic email pattern is listed before the bare "@" scrub so a
# full address gets replaced wholesale as one token, rather than losing its
# "@" first and then falling through the email regex unmatched.
#
# Ordering assumption vs. truncation: this pass runs on the already-assembled
# line, i.e. *after* rule (d) has truncated tool_use.input strings to 60
# chars. If a flagged name straddles that 60-char boundary (e.g. only "jarv"
# of "jarvis" survives in the kept prefix, with the rest already replaced by
# the numeric marker), the literal word patterns below won't match the
# truncated fragment — accepted as a low-severity residual since a 4-char
# fragment isn't clearly identifying and everything past it is already a
# marker, not raw content. The home-path pattern is unaffected by this: it
# matches "/Users/<up-to-the-next-separator>" greedily, and the marker text
# itself contains no "/", so it still folds any truncated username+marker
# run into a single "/redacted/home" replacement.
LEAK_PATTERNS = [
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "[redacted-email]"),
    (re.compile(r"@"), "(at)"),
    (re.compile(r"sk-", re.IGNORECASE), "sk_"),
    (re.compile(r"ghp_", re.IGNORECASE), "ghpx"),
    (re.compile(r"oliver", re.IGNORECASE), "person"),
    (re.compile(r"ollie", re.IGNORECASE), "person"),
    (re.compile(r"jarvis", re.IGNORECASE), "person"),
    # Real home-directory usernames survive the 40/60-char thresholds inside
    # short paths (e.g. a truncated tool_use.input file_path). Strip the
    # username segment but keep the rest of the path for structural fidelity.
    (re.compile(r"/Users/[^/\"\\\s]+"), "/redacted/home"),
]

ALLOWLIST_KEYS = {
    "type", "subtype", "name", "id", "uuid", "parentUuid", "sessionId",
    "message_id", "model", "stop_reason", "role", "tool_use_id", "toolUseId",
    "agentType", "hook_event_name", "timestamp", "requestId", "agentId",
    "version", "cwd", "gitBranch",
}
KEPT_TYPES = {"user", "assistant", "system", "attachment"}
MAX_VALUE_LEN = 40
MAX_INPUT_LEN = 60


class Redactor:
    """Tracks a deterministic, incrementing counter for redaction markers."""

    def __init__(self):
        self.count = 0

    def marker(self, length):
        self.count += 1
        return f"[redacted-{self.count}-chars-{length}]"


def redact_string(value, key, in_tool_input, redactor):
    if key == "cwd":
        return "/redacted/project"
    if key == "gitBranch":
        return "main"
    if key in ALLOWLIST_KEYS:
        return value
    if in_tool_input:
        if len(value) > MAX_INPUT_LEN:
            kept, rest = value[:MAX_INPUT_LEN], value[MAX_INPUT_LEN:]
            return kept + redactor.marker(len(rest))
        return value
    if len(value) > MAX_VALUE_LEN:
        return redactor.marker(len(value))
    return value


def walk(node, redactor, key=None, in_tool_input=False):
    """Recurse into dicts and lists alike, carrying the nearest enclosing
    dict key down through list elements — a string sitting directly inside
    a list (e.g. attachment.content: ["..."]) is redacted under its
    parent field's key, exactly as a same-length string value would be.
    """
    if isinstance(node, dict):
        is_tool_use = node.get("type") == "tool_use"
        out = {}
        for k, v in node.items():
            child_in_input = in_tool_input or (is_tool_use and k == "input")
            out[k] = walk(v, redactor, key=k, in_tool_input=child_in_input)
        return out
    if isinstance(node, list):
        return [walk(item, redactor, key=key, in_tool_input=in_tool_input) for item in node]
    if isinstance(node, str):
        return redact_string(node, key, in_tool_input, redactor)
    return node


def process_line(raw_line, redactor):
    """Returns the redacted JSON line, or None if it should be dropped."""
    line = raw_line.strip()
    if not line:
        return None
    obj = json.loads(line)
    if isinstance(obj, dict) and "type" in obj and obj["type"] not in KEPT_TYPES:
        return None
    redacted = walk(obj, redactor)
    text = json.dumps(redacted, ensure_ascii=False)
    for pattern, replacement in LEAK_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def main():
    if len(sys.argv) != 3:
        print("usage: redact-claude-fixture.py <input.jsonl> <output.jsonl>", file=sys.stderr)
        sys.exit(1)
    in_path, out_path = sys.argv[1], sys.argv[2]

    redactor = Redactor()
    kept = 0
    dropped = 0
    out_lines = []
    with open(in_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            if not raw_line.strip():
                continue
            result = process_line(raw_line, redactor)
            if result is None:
                dropped += 1
            else:
                kept += 1
                out_lines.append(result)

    with open(out_path, "w", encoding="utf-8") as f:
        for line in out_lines:
            f.write(line + "\n")

    print(f"kept={kept} dropped={dropped} strings_redacted={redactor.count}")


if __name__ == "__main__":
    main()
