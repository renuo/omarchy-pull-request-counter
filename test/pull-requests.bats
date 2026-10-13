setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../pull-requests.sh"
  PATH="$BATS_TEST_DIRNAME/fakebin:$PATH"
  export FAKE_GH_ARGS="$BATS_TEST_TMPDIR/gh-args"
  export FAKE_GH_STDOUT="$BATS_TEST_TMPDIR/gh-stdout"
  unset FAKE_GH_STDERR FAKE_GH_EXIT
  : >"$FAKE_GH_STDOUT"
}

# Fixture timestamps read "DAYS_AGO n" so ages stay stable whatever day it is.
stage_response() {
  jq 'walk(if type == "string" and startswith("DAYS_AGO ")
           then (now - ((ltrimstr("DAYS_AGO ") | tonumber) * 86400) | todate)
           else . end)' "$BATS_TEST_DIRNAME/fixtures/response.json" >"$FAKE_GH_STDOUT"
}

numbers() {
  jq -c --arg key "$1" '[.groups[] | select(.key == $key) | .prs[].number]' <<<"$output"
}

field() {
  jq -r "$1" <<<"$output"
}

query() {
  grep -v '^api$\|^graphql$\|^-f$' "$FAKE_GH_ARGS"
}

# Runs the script with only the given tools on PATH.
run_with_only() {
  local bin="$BATS_TEST_TMPDIR/only-bin"
  mkdir -p "$bin"
  local tool
  for tool in "$@"; do ln -sf "$(command -v "$tool")" "$bin/$tool"; done
  PATH="$bin" run "$(command -v bash)" "$SCRIPT"
}

@test "sorts every pull request into its group, newest first" {
  stage_response
  run bash "$SCRIPT" "renuo/devs"
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = true ]
  [ "$(field .login)" = me ]
  [ "$(field .error)" = "" ]
  [ "$(field '[.groups[].key] | join(",")')" = "reviewRequested,teamReviewRequested,noReviewRequested,allReviewsDone,missingAssignee,allAssigned" ]
  [ "$(numbers reviewRequested)" = "[1,3]" ]
  [ "$(numbers teamReviewRequested)" = "[2,30]" ]
  [ "$(numbers noReviewRequested)" = "[10,13]" ]
  [ "$(numbers allReviewsDone)" = "[11]" ]
  [ "$(numbers missingAssignee)" = "[20]" ]
  [ "$(numbers allAssigned)" = "[10,11,12,13]" ]
}

@test "shapes each pull request for the widget" {
  stage_response
  run bash "$SCRIPT"
  [ "$(jq -c '.groups[0].prs[0] | del(.createdAt)' <<<"$output")" = '{"title":"Mine to review","number":1,"url":"https://github.com/renuo/app/pull/1","repo":"renuo/app","owner":"renuo","author":"ann","draft":false,"ageInDays":2,"assigneeCount":0,"reviewRequestCount":1,"reviewCount":0}' ]
}

@test "fills in defaults for missing fields" {
  stage_response
  run bash "$SCRIPT"
  [ "$(jq -c '.groups[1].prs[] | select(.number == 30) | {author, draft, assigneeCount, reviewRequestCount, reviewCount}' <<<"$output")" = '{"author":"ghost","draft":false,"assigneeCount":0,"reviewRequestCount":0,"reviewCount":0}' ]
  [ "$(jq '.groups[0].prs[] | select(.number == 3) | .author' <<<"$output")" = '"ghost"' ]
  [ "$(jq '.groups[4].prs[0].ageInDays' <<<"$output")" = 0 ]
}

@test "keeps only owners in scope, case insensitively" {
  stage_response
  run bash "$SCRIPT" "" " other , "
  [ "$(numbers reviewRequested)" = "[3]" ]
  [ "$(numbers teamReviewRequested)" = "[]" ]
  [ "$(numbers allAssigned)" = "[]" ]
}

@test "drops own old pull requests but never review requests" {
  stage_response
  run bash "$SCRIPT" "" "" 3
  [ "$(numbers reviewRequested)" = "[1,3]" ]
  [ "$(numbers noReviewRequested)" = "[]" ]
  [ "$(numbers allAssigned)" = "[]" ]
  [ "$(numbers missingAssignee)" = "[20]" ]
}

@test "asks for one search per team, skipping blanks" {
  stage_response
  run bash "$SCRIPT" " renuo/devs, ,renuo/ops "
  query | grep -q 'teamReview0: search(query: "is:open is:pr team-review-requested:renuo/devs archived:false"'
  query | grep -q 'teamReview1: search(query: "is:open is:pr team-review-requested:renuo/ops archived:false"'
  [ "$(query | grep -c teamReview2)" = 0 ]
}

@test "asks for no team search without teams" {
  stage_response
  run bash "$SCRIPT"
  [ "$(query | grep -c teamReview)" = 0 ]
  query | grep -q 'reviewRequested: search(query: "is:open is:pr review-requested:@me archived:false", type: ISSUE, first: 50)'
}

@test "clamps the result limit" {
  stage_response
  run bash "$SCRIPT" "" "" 999 5
  query | grep -q 'first: 10)'
  run bash "$SCRIPT" "" "" 999 500
  query | grep -q 'first: 100)'
  run bash "$SCRIPT" "" "" 999 lots
  query | grep -q 'first: 50)'
}

@test "falls back to the default age for a non-number" {
  stage_response
  run bash "$SCRIPT" "" "" soon
  [ "$(field .ok)" = true ]
  [ "$(numbers allAssigned)" = "[10,11,12,13]" ]
}

@test "reports GraphQL errors next to partial data" {
  jq -n '{data: {viewer: {login: "me"}}, errors: [{message: "SAML enforced"}, {message: "no team"}]}' >"$FAKE_GH_STDOUT"
  run bash "$SCRIPT"
  [ "$(field .ok)" = true ]
  [ "$(field .error)" = "SAML enforced; no team" ]
  [ "$(field '[.groups[].prs | length] | add')" = 0 ]
}

@test "tells a logged out user how to log in" {
  export FAKE_GH_STDERR="To get started with GitHub CLI, please run:  gh auth login"
  export FAKE_GH_EXIT=4
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = false ]
  [ "$(field .error)" = "Not logged in to GitHub" ]
  [ "$(field .hint)" = "Run: gh auth login --scopes repo,read:org" ]
}

@test "treats a revoked token as logged out" {
  echo '{"message": "Bad credentials"}' >"$FAKE_GH_STDOUT"
  export FAKE_GH_EXIT=1
  run bash "$SCRIPT"
  [ "$(field .error)" = "Not logged in to GitHub" ]
}

@test "explains the rate limit" {
  export FAKE_GH_STDERR="API rate limit exceeded"
  export FAKE_GH_EXIT=1
  run bash "$SCRIPT"
  [ "$(field .error)" = "GitHub API rate limit reached" ]
}

@test "blames the network when gh says nothing" {
  export FAKE_GH_EXIT=1
  run bash "$SCRIPT"
  [ "$(field .error)" = "GitHub returned no data (exit 1)" ]
  [ "$(field .hint)" = "Check your network connection" ]
}

@test "passes any other gh error through" {
  printf 'not json' >"$FAKE_GH_STDOUT"
  export FAKE_GH_STDERR="something
odd"
  export FAKE_GH_EXIT=1
  run bash "$SCRIPT"
  [ "$(field .error)" = "something odd " ]
}

@test "passes an API message through" {
  echo '[]' >"$FAKE_GH_STDOUT"
  run bash "$SCRIPT"
  [ "$(field .error)" = "GitHub returned no data (exit 0)" ]
  echo '{"message": "Server Error"}' >"$FAKE_GH_STDOUT"
  run bash "$SCRIPT"
  [ "$(field .error)" = "Server Error" ]
}

@test "needs jq" {
  run_with_only
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":false,"login":"","error":"jq is not installed","hint":"sudo pacman -S jq","groups":[]}' ]
}

@test "needs gh" {
  run_with_only jq
  [ "$status" -eq 0 ]
  [ "$(field .error)" = "GitHub CLI (gh) is not installed" ]
  [ "$(field .hint)" = "Install it with: sudo pacman -S github-cli" ]
}
