#!/bin/bash

# Emits every pull request the bar widget renders as one JSON object on stdout.
#
#   { "ok": true, "login": "...", "error": "", "groups": [ { "key": ..., "prs": [...] } ] }
#
# The grouping mirrors renuo/github-pull-request-counter, but the six category
# queries of the browser extension collapse into a single GraphQL request:
# the extension asks the search API once per category and then fetches
# `requested_reviewers` per pull request, which burns through the 30 req/min
# search budget on any real workday. GraphQL returns `reviewRequests` and
# `reviews` inline, so "no review requested" and "all reviews done" are a
# client-side split of one `assignee:@me` search.
#
# Usage: pull-requests.sh [teams] [scope] [maxAgeDays] [limit]
#   teams       comma separated org/team-slug list ("" to skip team queries)
#   scope       comma separated owner allow-list ("" for every owner)
#   maxAgeDays  drop own pull requests older than this (999 = keep all)
#   limit       max pull requests per query (10-100)
#
# Failures are reported as `{"ok": false, "error": ...}` with exit 0: the widget
# renders the message in its panel, and a non-zero exit would only make the QML
# side guess at what went wrong.

set -uo pipefail

teams="${1:-}"
scope="${2:-}"
max_age_days="${3:-999}"
limit="${4:-50}"

[[ $max_age_days =~ ^[0-9]+$ ]] || max_age_days=999
[[ $limit =~ ^[0-9]+$ ]] || limit=50
((limit < 10)) && limit=10
((limit > 100)) && limit=100

emit_error() {
  jq -n --arg error "$1" --arg hint "${2:-}" \
    '{ok: false, login: "", error: $error, hint: $hint, groups: []}'
  exit 0
}

json_string() { jq -Rn --arg v "$1" '$v'; }

if ! command -v jq >/dev/null 2>&1; then
  printf '{"ok":false,"login":"","error":"jq is not installed","hint":"sudo pacman -S jq","groups":[]}\n'
  exit 0
fi

command -v gh >/dev/null 2>&1 ||
  emit_error "GitHub CLI (gh) is not installed" "Install it with: sudo pacman -S github-cli"

# ------------------------------------------------------------------ the query

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pr_fields=$(<"$here/pull-request-fields.graphql")

team_queries=""
team_index=0
IFS=',' read -ra team_list <<<"$teams"
for team in "${team_list[@]}"; do
  team="${team//[[:space:]]/}"
  [[ -n $team ]] || continue
  team_queries+="  teamReview${team_index}: search(query: $(json_string "is:open is:pr team-review-requested:${team} archived:false"), type: ISSUE, first: ${limit}) { nodes { ...prFields } }"$'\n'
  team_index=$((team_index + 1))
done

query="query {
  viewer { login }
  reviewRequested: search(query: $(json_string 'is:open is:pr review-requested:@me archived:false'), type: ISSUE, first: ${limit}) { nodes { ...prFields } }
  assigned: search(query: $(json_string 'is:open is:pr assignee:@me archived:false'), type: ISSUE, first: ${limit}) { nodes { ...prFields } }
  authored: search(query: $(json_string 'is:open is:pr author:@me draft:false archived:false'), type: ISSUE, first: ${limit}) { nodes { ...prFields } }
${team_queries}}

${pr_fields}"

stderr_file=$(mktemp)
response=$(gh api graphql -f query="$query" 2>"$stderr_file")
gh_status=$?
gh_error=$(tr '\n' ' ' <"$stderr_file" | cut -c1-400)
rm -f "$stderr_file"

# An expired or revoked token is not a transport failure: gh prints a perfectly
# well-formed `{"message": "Bad credentials"}` on stdout and only mentions the
# problem on stderr. Treat "parsed fine but carries no `data`" as an error too,
# or the transform below runs against a null and reports a jq crash instead of
# the one thing the user can act on.
api_message=""
if jq -e . >/dev/null 2>&1 <<<"$response"; then
  api_message=$(jq -r 'if type == "object" then (.message // "") else "" end' <<<"$response")
fi

if [[ -z $response ]] || ! jq -e 'type == "object" and .data != null' >/dev/null 2>&1 <<<"$response"; then
  case "$gh_error$api_message" in
  *"gh auth login"* | *"authentication token"* | *"Bad credentials"*)
    emit_error "Not logged in to GitHub" "Run: gh auth login --scopes repo,read:org"
    ;;
  *"rate limit"* | *"API rate limit"*)
    emit_error "GitHub API rate limit reached" "Raise the refresh interval and try again shortly"
    ;;
  "")
    emit_error "GitHub returned no data (exit ${gh_status})" "Check your network connection"
    ;;
  *)
    emit_error "${gh_error:-$api_message}" ""
    ;;
  esac
fi

# ------------------------------------------------------------- the transform

jq -n \
  --argjson data "$response" \
  --arg scope "$scope" \
  --argjson maxAge "$max_age_days" \
  -f "$here/transform.jq"
