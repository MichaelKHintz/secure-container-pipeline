#!/usr/bin/env bash
# Redact account- and person-identifying details before an evidence file is committed.
# Usage: scripts/redact.sh evidence-raw/falco.log docs/evidence/falco.log
set -euo pipefail
in="$1"; out="$2"
acct="$(aws sts get-caller-identity --query Account --output text)"
ACCT="$acct" perl -pe '
  s/$ENV{ACCT}/<AWS_ACCOUNT_ID>/g;
  s/[\w.%+-]+\@[\w.-]+\.[A-Za-z]{2,}/<EMAIL>/g;
  s/[0-9A-F]{32}\.[a-z0-9]+\.us-west-2\.eks\.amazonaws\.com/<EKS_ENDPOINT>/g;
  s{/Users/[^/\s]+}{/Users/<USER>}g;
' "$in" > "$out"
if grep -nE "$acct|@[A-Za-z0-9-]+\." "$out"; then
  echo "WARNING: possible identifier left in $out" >&2
fi
