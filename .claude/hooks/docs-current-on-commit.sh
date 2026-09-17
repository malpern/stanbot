#!/bin/bash
# PreToolUse(Bash): before a `git commit` that changes code, require that docs
# were updated in the same commit, or that the message says why none were needed.
input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
cwd=$(jq -r '.cwd // "."' <<<"$input")
grep -qE '(^|[;&|[:space:]])git( -C [^ ]+)? commit' <<<"$cmd" || exit 0
grep -q -- '--amend' <<<"$cmd" && exit 0
grep -q '\[no-docs\]' <<<"$cmd" && exit 0

cd "$cwd" 2>/dev/null || exit 0
if grep -qE 'commit[^;&|]* (-a|--all|-[a-zA-Z]*a[a-zA-Z]*)( |$)' <<<"$cmd"; then
  files=$( { git diff --name-only HEAD; git diff --cached --name-only; } 2>/dev/null | sort -u)
else
  files=$(git diff --cached --name-only 2>/dev/null)
fi
[ -z "$files" ] && exit 0
code=$(grep -vE '(\.md$|^docs/|^\.claude/)' <<<"$files")
docs=$(grep -E '(\.md$|^docs/)' <<<"$files")
[ -z "$code" ] && exit 0
[ -n "$docs" ] && exit 0

reason="Docs check: this commit changes code but no documentation:
$(sed 's/^/  /' <<<"$code")
Before committing, check that docs/ and README.md reflect this change (status, open problems, session results, checklists) and stage the updates. If truly no doc change is needed, add [no-docs] to the commit message with a one-line reason."
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
