# Pull Request Counter — Omarchy plugin

Open GitHub pull requests that need your attention, counted in the Omarchy bar.

A port of [renuo/github-pull-request-counter](https://github.com/renuo/github-pull-request-counter)
— the same six categories, the same "remove the mental load" idea — as a
first-class `bar-widget` plugin for the Omarchy shell instead of a browser
extension.

```
  5     ← the bar, dimmed at zero and urgent past the threshold
```

Click it and the panel lists every pull request, grouped:

| Group | What lands here |
|---|---|
| I must review | `review-requested:@me`, minus anything already covered by a team request |
| My team must review | `team-review-requested:<team>` for each configured team |
| No review requested | Assigned to you, nobody asked to review, no reviews yet |
| All reviews done | Assigned to you, nobody left to review, reviews exist |
| Missing assignee | Authored by you, not a draft, nobody assigned |
| Assigned to me | Everything `assignee:@me` |

## Requirements

- Omarchy 4 (the Quickshell-based `omarchy-shell`)
- `gh` and `jq` — `sudo pacman -S github-cli jq`
- A logged-in GitHub CLI: `gh auth login --scopes repo,read:org`

There is no access token to paste anywhere. The browser extension needs one
because a web page has no other credential; here `gh` already holds one, so the
plugin borrows it and stores nothing of its own.

## Install

```bash
git clone https://github.com/renuo/omarchy-pull-request-counter.git
cd omarchy-pull-request-counter
bin/run
```

`bin/run` copies the plugin into `~/.config/omarchy/plugins/renuo.pull-request-counter/`,
rescans, and enables it in the right-hand bar section. Move it elsewhere with:

```bash
omarchy bar move renuo.pull-request-counter --section center
```

Or install it the ordinary Omarchy way, without a checkout:

```bash
omarchy plugin add https://github.com/renuo/omarchy-pull-request-counter.git --enable
```

## Interactions

| Where | Action |
|---|---|
| Bar, left click | Open/close the panel |
| Bar, right click | Refresh now |
| Bar, middle click | Open github.com/pulls |
| List, left click a row | Open that pull request |
| List, right click a row | Ignore it, or stop ignoring it |
| List, `j`/`k` or arrows | Move the cursor |
| List, `Enter` | Open the selected pull request |
| Any view, `s` | Toggle the options form |
| Any view, `r` | Refresh |
| Any view, `g` | Open github.com/pulls |
| Any view, `Esc` | Back to the list, or close |

IPC, for keybinds and scripts:

```bash
omarchy-shell pull-requests toggle
omarchy-shell pull-requests options
omarchy-shell pull-requests refresh
omarchy-shell pull-requests count
```

## Options

The gear in the panel header (or `s`) swaps the list for the options form —
the browser extension's options page, rebuilt out of the shell's own controls.
There is no save button: every control writes straight back to this widget's
entry in `~/.config/omarchy/shell.json`, and the widget re-reads it from there,
so the form and the file can never disagree.

The form is driven by the same cursor as the list, because Qt's Tab traversal
does not reach into these layer-shell panels:

| Key | In the options form |
|---|---|
| `j`/`k` or arrows | Move between options |
| `h`/`l` or left/right | Step a number up or down |
| `Enter` | Toggle a checkbox, or start editing a text field |
| `Enter` while editing | Commit and hand the keyboard back |
| `Esc` while editing | Discard the edit |
| `Esc` | Back to the list |

Mouse works throughout; the number fields also take a typed value.

## Settings

Everything the options form writes is a plain key on the widget's entry in
`~/.config/omarchy/shell.json`, editable by hand just as well. It hot-reloads
on save:

```json
{
  "id": "renuo.pull-request-counter",
  "teams": "renuo/developers",
  "scope": "renuo",
  "maximumAgeDays": 30,
  "refreshIntervalSec": 300,
  "urgentThreshold": 3
}
```

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `300` | How often to poll GitHub |
| `teams` | `""` | Comma separated `org/team-slug` list for the team-review group |
| `scope` | `""` | Comma separated owner allow-list; empty means every owner |
| `maximumAgeDays` | `999` | Drop your own pull requests older than this from the last four groups |
| `ignoredPrs` | `""` | Comma separated `owner/repo#number` list to leave out of the count |
| `ignoredTitles` | `""` | Pull requests whose title matches this regular expression leave the count |
| `countGroups` | all but `allAssigned` | Which groups the bar number adds up |
| `urgentThreshold` | `3` | Count at which the bar number takes the theme's urgent color |
| `hideWhenEmpty` | `false` | Hide the widget entirely when the count is zero |
| `resultLimit` | `50` | Max pull requests fetched per query (10–100) |

`countGroups` takes the keys from the table above in camelCase:
`reviewRequested`, `teamReviewRequested`, `noReviewRequested`,
`allReviewsDone`, `missingAssignee`, `allAssigned`. It counts each pull request
once even when several selected groups contain it — the extension sums the
groups instead, which double-counts as soon as `allAssigned` is on.

Ignored pull requests stay in the list, struck through and greyed out, and only
drop out of the count — the extension's behavior. Right-clicking a row adds or
removes it from `ignoredPrs`, so the list is usable without typing
`owner/repo#number` by hand.

## How it fetches

One `gh api graphql` call per refresh, no matter how many groups are on screen.

The browser extension issues a search request per category and then one
`requested_reviewers` request per pull request, which the GitHub search API's
30-requests-per-minute budget does not love. GraphQL returns `reviewRequests`
and `reviews` inline, so "no review requested" and "all reviews done" become a
client-side split of a single `assignee:@me` search. Three searches plus one per
configured team, in one round trip.

Run the helper by hand to see exactly what the widget sees:

```bash
./pull-requests.sh "" "" 999 50 | jq '[.groups[] | {key, n: (.prs | length)}]'
```

## Development

On top of the requirements above, development needs:

- `bats` — `sudo pacman -S bash-bats`
- `kcov` — `yay -S kcov`
- `node` — `mise use -g node`

Edit here, then `bin/run` to push the changes into the plugin directory —
the shell watches it and hot-reloads on write. If a reload ever fails to take:

```bash
omarchy-shell shell rescanPlugins
```

One exception worth knowing: `Model.js` is a `.pragma library`, and the QML
engine caches those per URL for the life of the process. Edits to `Panel.qml`,
`Service.qml`, `manifest.json`, `pull-requests.sh`, `pull-request-fields.graphql`
and `transform.jq` hot-reload; edits to
`Model.js` need a restart:

```bash
omarchy restart shell
```

Convenience scripts:

```bash
bin/setup   # checks that every tool above is installed
bin/check   # validates the manifest, runs the tests, demands 100% line coverage
bin/run     # installs into the shell, which hot-reloads it
```

`Model.js` is tested with Node's built-in test runner and coverage;
`pull-requests.sh` with bats against a fake `gh` in `test/fakebin`, measured by
kcov. The QML files have no line coverage tool, which is one more reason to
keep logic in `Model.js`.

QML errors go to the shell's log:

```bash
journalctl --user -f | grep -i quickshell
```

Layout:

| File | Role |
|---|---|
| `manifest.json` | Plugin declaration and the settings schema |
| `Panel.qml` | Bar button plus the popup — the `barWidget` entry point |
| `Service.qml` | Polling loop, the one subprocess, parsed state |
| `Model.js` | Group metadata, JSON shaping, ignore rules, options cursor order |
| `pull-requests.sh` | Builds the GraphQL query, calls `gh`, reports failures |
| `pull-request-fields.graphql` | The fields fetched for every pull request |
| `transform.jq` | Shapes the GraphQL response into the widget's groups |
| `test/` | Node tests for `Model.js`, bats tests for `pull-requests.sh` |

## License

MIT, matching the upstream extension.
