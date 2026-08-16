import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the polling loop and the one subprocess this plugin runs. The panel
// reads `result` / `total` / `refreshing` off here and never touches Process.
Item {
  id: root

  property var settings: ({})
  // Absolute path to pull-requests.sh, injected by Panel.qml. Resolving it
  // there keeps this file free of assumptions about where the plugin landed:
  // a clone lives under ~/.config/omarchy/plugins/<id>/, a checkout may not.
  property string scriptPath: ""

  property var result: Model.emptyResult()
  property bool refreshing: false
  property string lastError: ""
  property double lastRefreshMs: 0

  readonly property var groups: Model.applyIgnores(result.groups, ignoredPrs, ignoredTitles)
  readonly property int total: Model.totalCount(groups)
  readonly property int countedTotal: Model.countedTotal(groups, countGroups)
  readonly property int ignoredTotal: Model.ignoredCount(groups)
  readonly property bool connected: result.ok && lastRefreshMs > 0
  readonly property string errorText: lastError !== "" ? lastError : String(result.error || "")
  readonly property string hintText: String(result.hint || "")

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 300, 30, 3600)
  readonly property int urgentThreshold: intSetting("urgentThreshold", 3, 1, 99)
  readonly property int resultLimit: intSetting("resultLimit", 50, 10, 100)
  readonly property int maximumAgeDays: intSetting("maximumAgeDays", 999, 1, 999)
  readonly property string teams: String(setting("teams", ""))
  readonly property string scope: String(setting("scope", ""))
  readonly property string countGroups: String(setting("countGroups", Model.DEFAULT_COUNT_GROUPS))
  readonly property string ignoredPrs: String(setting("ignoredPrs", ""))
  readonly property string ignoredTitles: String(setting("ignoredTitles", ""))
  readonly property string ignoredTitlesError: Model.regexError(ignoredTitles)
  readonly property bool hideWhenEmpty: setting("hideWhenEmpty", false) === true

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function refresh() {
    if (fetchProcess.running || scriptPath === "") return
    refreshing = true
    fetchProcess.command = [
      "bash",
      scriptPath,
      teams,
      scope,
      String(maximumAgeDays),
      String(resultLimit)
    ]
    fetchProcess.running = true
  }

  function openPullRequest(pr) {
    if (!pr || !pr.url) return
    Qt.openUrlExternally(String(pr.url))
  }

  function openGithubPulls() {
    Qt.openUrlExternally("https://github.com/pulls")
  }

  // A settings edit changes what the next fetch asks GitHub for, so re-run it
  // rather than leaving stale groups on screen until the interval elapses.
  onTeamsChanged: settingsDebounce.restart()
  onScopeChanged: settingsDebounce.restart()
  onMaximumAgeDaysChanged: settingsDebounce.restart()
  onResultLimitChanged: settingsDebounce.restart()

  Timer {
    id: settingsDebounce
    interval: 400
    onTriggered: if (root.lastRefreshMs > 0) root.refresh()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.lastRefreshMs > 0
    onTriggered: root.refresh()
  }

  // The search API is the tightest budget GitHub gives us (30 requests per
  // minute), and every bar surface — one per monitor — polls independently.
  // Jittering the first fetch keeps a three-monitor session from firing three
  // identical queries in the same millisecond, and staggers the intervals that
  // follow, since each surface's repeat timer starts from its own first tick.
  Timer {
    id: startupJitter
    interval: 200 + Math.floor(Math.random() * 2500)
    running: root.scriptPath !== ""
    onTriggered: root.refresh()
  }

  Process {
    id: fetchProcess
    running: false
    command: []
    stdout: StdioCollector { id: fetchStdout; waitForEnd: true }
    stderr: StdioCollector { id: fetchStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      // Stamped even on failure: the periodic timer keys off it, and a helper
      // that died once must not leave the widget frozen until the next restart.
      root.lastRefreshMs = Date.now()
      if (exitCode !== 0) {
        root.lastError = elide(String(fetchStderr.text || "") || "Could not read pull requests (exit " + exitCode + ")")
        return
      }
      root.result = Model.parse(String(fetchStdout.text || ""))
      root.lastError = ""
    }
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
    return value.length > 160 ? value.substring(0, 157) + "…" : value
  }
}
