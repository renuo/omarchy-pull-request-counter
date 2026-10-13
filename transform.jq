def trimmed_list: (. // "") | split(",") | map(sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(length > 0));

def to_pr($now):
  (.repository.nameWithOwner // "") as $repo
  | {
      title: (.title // ""),
      number: (.number // 0),
      url: (.url // ""),
      repo: $repo,
      owner: ($repo | split("/") | .[0] // ""),
      author: (.author.login // "ghost"),
      draft: (.isDraft // false),
      createdAt: (.createdAt // ""),
      ageInDays: (if (.createdAt // "") == "" then 0
                  else ((($now - (.createdAt | fromdateiso8601)) / 86400) | floor) end),
      assigneeCount: (.assignees.totalCount // 0),
      reviewRequestCount: (.reviewRequests.totalCount // 0),
      reviewCount: (.reviews.totalCount // 0)
    };

def pulls($key; $now): [ (($data.data // {})[$key].nodes // [])[] | select(.url != null) | to_pr($now) ];
def in_scope($scopes):
  map(select(($scopes | length) == 0
             or ((.owner | ascii_downcase) as $owner | ($scopes | index($owner)) != null)));
def young($max): map(select(.ageInDays < $max));
def newest_first: sort_by(.createdAt) | reverse;
def by_url: group_by(.url) | map(.[0]);

now as $now
| ($scope | trimmed_list | map(ascii_downcase)) as $scopes
| ([ ($data.errors // [])[] | .message ] | join("; ")) as $gqlError
| pulls("reviewRequested"; $now) as $reviewRequested
| pulls("assigned"; $now) as $assigned
| pulls("authored"; $now) as $authored
| ([ ($data.data // {}) | to_entries[] | select(.key | startswith("teamReview")) | .value.nodes[]?
     | select(.url != null) | to_pr($now) ] | by_url) as $teamReview
| ($teamReview | map(.url)) as $teamUrls
| {
    ok: true,
    login: (($data.data // {}).viewer.login // ""),
    error: $gqlError,
    hint: "",
    groups: [
      { key: "reviewRequested",
        prs: ($reviewRequested | map(select((.url as $u | $teamUrls | index($u)) == null)) | in_scope($scopes) | newest_first) },
      { key: "teamReviewRequested",
        prs: ($teamReview | in_scope($scopes) | newest_first) },
      { key: "noReviewRequested",
        prs: ($assigned | map(select(.reviewRequestCount == 0 and .reviewCount == 0)) | in_scope($scopes) | young($maxAge) | newest_first) },
      { key: "allReviewsDone",
        prs: ($assigned | map(select(.reviewRequestCount == 0 and .reviewCount > 0)) | in_scope($scopes) | young($maxAge) | newest_first) },
      { key: "missingAssignee",
        prs: ($authored | map(select(.assigneeCount == 0)) | in_scope($scopes) | young($maxAge) | newest_first) },
      { key: "allAssigned",
        prs: ($assigned | in_scope($scopes) | young($maxAge) | newest_first) }
    ]
  }
