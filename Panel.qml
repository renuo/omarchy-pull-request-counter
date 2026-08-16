import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget plus its popup, in the shape the Omarchy bar expects from a
// `bar-widget` entry point: an Item sized to its button, with the popup
// mounted as a layer-shell panel anchored to that button.
//
// The popup has two faces. The list is the default; the gear swaps in the
// options form, which is the browser extension's options page rebuilt out of
// the shell's own controls. Every control writes straight back to this
// widget's inline entry in shell.json, so there is no save button and no
// second copy of the configuration to keep in sync.
Panel {
  id: root
  moduleName: "renuo.pull-request-counter"
  ipcTarget: "pull-requests"
  manageIpc: false

  property bool cursorActive: false
  property int rowIndex: 0
  property int optionIndex: 0
  property bool showSettings: false

  // Number of form controls currently holding focus. The key catcher swallows
  // j/k/h/l, Enter, Space, Tab and Esc, so it has to stand down entirely while
  // a text field or spin box owns input — otherwise "j" scrolls the panel
  // instead of landing in the field.
  property int editorFocusCount: 0
  readonly property bool editing: editorFocusCount > 0
  function noteEditorFocus(on) {
    editorFocusCount = Math.max(0, editorFocusCount + (on ? 1 : -1))
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var visibleGroups: Model.nonEmptyGroups(github.groups)
  readonly property var rows: showSettings ? [] : Model.flatten(visibleGroups)

  readonly property int badgeCount: github.countedTotal
  readonly property bool urgentBadge: badgeCount >= github.urgentThreshold
  // Three states, in the spirit of the extension's green/amber/red badge, but
  // spelled in theme roles instead of literal colors so the widget still reads
  // as part of whatever theme is loaded: nothing waiting is dimmed out of the
  // way, a normal queue is plain foreground, and past the threshold it takes
  // the bar's urgent role.
  readonly property color badgeColor: !github.connected || github.errorText !== ""
    ? Qt.darker(barForeground, 1.55)
    : (badgeCount === 0
      ? Qt.darker(barForeground, 1.35)
      : (urgentBadge ? (bar ? bar.urgent : Color.urgent) : barForeground))

  readonly property string badgeText: {
    if (!github.connected && github.refreshing) return Model.GITHUB_GLYPH + " …"
    if (github.errorText !== "") return Model.GITHUB_GLYPH + " !"
    return Model.GITHUB_GLYPH + " " + badgeCount
  }

  // ------------------------------------------------------------- persistence

  // shell.json stores one inline object per bar entry, and updateEntryInline
  // replaces it wholesale — so carry every existing key forward, or editing
  // the refresh interval would quietly drop the team list.
  function persistSettings(changes) {
    var entry = { id: moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    for (var changed in changes) entry[changed] = changes[changed]

    // Applied locally first so the control reacts on the click itself; the
    // shell.json write comes back through the bar as the same value.
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  function persistSetting(key, value) {
    var change = {}
    change[key] = value
    persistSettings(change)
  }

  function toggleCountGroup(key) {
    persistSetting("countGroups", Model.toggleInList(github.countGroups, key))
  }

  function toggleIgnored(pr) {
    if (!pr) return
    persistSetting("ignoredPrs", Model.toggleInList(github.ignoredPrs, Model.ignoreKey(pr)))
  }

  // --------------------------------------------------------- keyboard cursor

  function ensureCursor() {
    if (showSettings) {
      optionIndex = Math.max(0, Math.min(Model.optionCount() - 1, optionIndex))
      return
    }
    if (rows.length === 0) { rowIndex = 0; return }
    if (rowIndex >= rows.length) rowIndex = rows.length - 1
    if (rowIndex < 0) rowIndex = 0
  }

  // dy walks the cursor; dx adjusts the row under it, which is what makes
  // h/l step the numeric options without opening an editor.
  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (showSettings) {
      if (dx !== 0) { adjustOption(dx); return }
      if (dy === 0) return
      optionIndex = Math.max(0, Math.min(Model.optionCount() - 1, optionIndex + dy))
      scrollOptionIntoView()
      return
    }
    if (dy === 0 || rows.length === 0) return
    rowIndex = Math.max(0, Math.min(rows.length - 1, rowIndex + dy))
    scrollCursorIntoView()
  }

  function setRowCursor(index) {
    cursorActive = true
    rowIndex = index
    scrollCursorIntoView()
  }

  function setOptionCursor(index) {
    cursorActive = true
    optionIndex = index
  }

  function activateCursor() {
    ensureCursor()
    if (showSettings) { activateOption(); return }
    if (rows.length === 0) return
    github.openPullRequest(rows[rowIndex])
    root.close()
  }

  function toggleSettings() {
    showSettings = !showSettings
    cursorActive = false
    rowIndex = 0
    optionIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Option rows register themselves by cursor index and expose activate() and,
  // where it means something, adjust(). The panel drives them through this
  // registry so the key handling stays one small switch instead of a chain of
  // "which control is selected" conditionals.
  property var optionRegistry: ({})
  function registerOption(index, item) { if (index >= 0) optionRegistry[index] = item }
  function unregisterOption(index, item) { if (optionRegistry[index] === item) delete optionRegistry[index] }

  function activateOption() {
    var item = optionRegistry[optionIndex]
    if (item && typeof item.activate === "function") item.activate()
  }

  function adjustOption(delta) {
    var item = optionRegistry[optionIndex]
    if (item && typeof item.adjust === "function") item.adjust(delta)
  }

  function scrollOptionIntoView() {
    scrollItemIntoView(optionRegistry[optionIndex])
  }

  function scrollCursorIntoView() {
    if (rowIndex < 0 || rowIndex >= rows.length) return
    scrollItemIntoView(rowRegistry[rowIndex])
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  // Row items register themselves by flat index so the keyboard cursor can
  // scroll to a row it has never rendered, without the panel having to walk
  // nested Repeaters to find one.
  property var rowRegistry: ({})
  function registerRow(index, item) { rowRegistry[index] = item }
  function unregisterRow(index, item) { if (rowRegistry[index] === item) delete rowRegistry[index] }

  visible: !(github.hideWhenEmpty && github.connected && github.errorText === "" && badgeCount === 0)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onRowsChanged: ensureCursor()

  onOpenedChanged: if (opened) {
    cursorActive = false
    rowIndex = 0
    showSettings = false
    editorFocusCount = 0
    if (panelFlick) panelFlick.contentY = 0
    github.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: github
    settings: root.settings
    scriptPath: Model.pathFromUrl(Qt.resolvedUrl("pull-requests.sh"))
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { github.refresh(); return "ok" }
    function count(): string { return String(root.badgeCount) }
    function options(): void { root.open(); root.showSettings = true }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.badgeText
    fontSize: Style.bar.iconFont
    foreground: root.badgeColor
    useActiveColor: false
    tooltipText: ""

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) github.refresh()
      else if (buttonCode === Qt.MiddleButton) github.openGithubPulls()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.showSettings ? root.toggleSettings() : root.close()
      // Swallowed in the options view: Tab belongs to the form's controls
      // there, not to the bar's next popup.
      onTabRequested: function(direction) { if (!root.showSettings) root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") github.refresh()
        else if (t === "s" || t === "S") root.toggleSettings()
        else if (t === "g" || t === "G") { github.openGithubPulls(); root.close() }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: root.showSettings ? "Options" : "Pull Requests"
            meta: root.showSettings
              ? "Saved to shell.json as you edit"
              : Model.heroMeta(github.result, github.total, github.ignoredTotal, github.refreshing)
            foreground: root.foreground
            fontFamily: root.fontFamily
            // `root` inside these components resolves to PanelHero, not this
            // Panel, so they reach hero state through `hero` instead.
            iconComponent: Component {
              Text {
                text: Model.GITHUB_GLYPH
                color: hero.foreground
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(6)

                PanelActionButton {
                  iconText: root.showSettings ? "" : ""
                  tooltipText: root.showSettings ? "Back to the list" : "Options"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  onClicked: root.toggleSettings()
                }

                PanelActionButton {
                  visible: !root.showSettings
                  iconText: ""
                  tooltipText: "Refresh"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  enabled: !github.refreshing
                  onClicked: github.refresh()
                }
              }
            }
          }

          // ------------------------------------------------------- list view

          Column {
            visible: !root.showSettings
            width: parent.width
            spacing: Style.space(12)

            Column {
              visible: github.errorText !== ""
              width: parent.width
              spacing: Style.spacing.labelGap

              Text {
                width: parent.width
                text: github.errorText
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Text {
                visible: github.hintText !== ""
                width: parent.width
                text: github.hintText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Text {
              visible: github.errorText === "" && root.rows.length === 0
              width: parent.width
              text: github.connected ? "Nothing waiting on you." : "Loading…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.visibleGroups

              Column {
                id: groupColumn
                required property var modelData
                required property int index
                readonly property int offset: Model.groupOffset(root.visibleGroups, index)

                width: column.width
                spacing: Style.space(6)
                topPadding: index === 0 ? 0 : Style.space(4)

                PanelSectionHeader {
                  text: groupColumn.modelData.glyph + "   " + groupColumn.modelData.label.toUpperCase()
                      + "   " + groupColumn.modelData.prs.length
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: groupColumn.modelData.prs

                  PullRequestRow {
                    required property var modelData
                    required property int index
                    width: groupColumn.width
                    pr: modelData
                    flatIndex: groupColumn.offset + index
                  }
                }
              }
            }
          }

          // ---------------------------------------------------- options view

          Column {
            visible: root.showSettings
            width: parent.width
            spacing: Style.space(12)

            PanelSectionHeader {
              text: "COUNTER"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: "Which groups the bar number adds up."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: Model.GROUPS

                CheckRow {
                  required property var modelData
                  width: parent.width
                  label: modelData.glyph + "   " + modelData.label
                  optionIndex: Model.optionIndexOf("count:" + modelData.key)
                  checked: Model.listContains(github.countGroups, modelData.key)
                  onToggled: root.toggleCountGroup(modelData.key)
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "FILTERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            SettingText {
              width: parent.width
              label: "Teams"
              description: "Comma separated org/team-slug. Review requests for a team listed here move out of \"I must review\" into their own group."
              placeholder: "renuo/developers, renuo/ops"
              settingKey: "teams"
              optionIndex: Model.optionIndexOf("teams")
              value: github.teams
            }

            SettingText {
              width: parent.width
              label: "Scope"
              description: "Only fetch from these GitHub owners, case insensitive. Empty means every owner."
              placeholder: "renuo, my-other-org"
              settingKey: "scope"
              optionIndex: Model.optionIndexOf("scope")
              value: github.scope
            }

            SettingNumber {
              width: parent.width
              label: "Maximum age (days)"
              description: "Drops your own older pull requests. Does not apply to the two review-requested groups."
              settingKey: "maximumAgeDays"
              optionIndex: Model.optionIndexOf("maximumAgeDays")
              value: github.maximumAgeDays
              from: 1
              to: 999
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "IGNORED"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: "Ignored pull requests stay in the list, greyed out, and drop out of the count. Right-click any row to add or remove it here."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            SettingText {
              width: parent.width
              label: "Pull requests"
              placeholder: "owner/repo#1, owner/repo#2"
              settingKey: "ignoredPrs"
              optionIndex: Model.optionIndexOf("ignoredPrs")
              value: github.ignoredPrs
            }

            SettingText {
              width: parent.width
              label: "Titles matching"
              description: "A regular expression tested against the title, case sensitive."
              placeholder: "^(chore|WIP)"
              settingKey: "ignoredTitles"
              optionIndex: Model.optionIndexOf("ignoredTitles")
              value: github.ignoredTitles
              errorText: github.ignoredTitlesError
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "BAR"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            SettingNumber {
              width: parent.width
              label: "Urgent at"
              description: "Count at which the bar number takes the theme's urgent color."
              settingKey: "urgentThreshold"
              optionIndex: Model.optionIndexOf("urgentThreshold")
              value: github.urgentThreshold
              from: 1
              to: 99
            }

            SettingNumber {
              width: parent.width
              label: "Refresh every (seconds)"
              settingKey: "refreshIntervalSec"
              optionIndex: Model.optionIndexOf("refreshIntervalSec")
              value: github.refreshIntervalSec
              from: 30
              to: 3600
              step: 30
            }

            SettingNumber {
              width: parent.width
              label: "Fetch per query"
              description: "Upper bound on pull requests returned by each GitHub search."
              settingKey: "resultLimit"
              optionIndex: Model.optionIndexOf("resultLimit")
              value: github.resultLimit
              from: 10
              to: 100
              step: 10
            }

            CheckRow {
              width: parent.width
              label: "Hide the widget when nothing is open"
              optionIndex: Model.optionIndexOf("hideWhenEmpty")
              checked: github.hideWhenEmpty
              onToggled: root.persistSetting("hideWhenEmpty", !github.hideWhenEmpty)
            }
          }
        }
      }
    }
  }

  // -------------------------------------------------------------- components

  component PullRequestRow: CursorSurface {
    id: prRow
    property var pr: null
    property int flatIndex: 0
    readonly property bool ignored: pr && pr.ignored === true

    hasCursor: root.cursorActive && root.rowIndex === flatIndex
    foreground: root.foreground
    opacity: ignored ? 0.45 : 1.0

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    Component.onCompleted: root.registerRow(flatIndex, prRow)
    Component.onDestruction: root.unregisterRow(flatIndex, prRow)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setRowCursor(prRow.flatIndex)
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) {
          root.toggleIgnored(prRow.pr)
          return
        }
        github.openPullRequest(prRow.pr)
        root.close()
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: Model.titleFor(prRow.pr)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.strikeout: prRow.ignored
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: Model.metaFor(prRow.pr)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // Compact checkbox row. The kit's Toggle is a 54px-tall switch row, which
  // would give the six counter checkboxes more of the popup than the pull
  // requests they configure.
  component CheckRow: CursorSurface {
    id: checkRow
    property string label: ""
    property bool checked: false
    property int optionIndex: -1
    signal toggled()

    function activate() { checkRow.toggled() }

    hasCursor: root.cursorActive && root.optionIndex === checkRow.optionIndex
    foreground: root.foreground

    implicitHeight: checkLabel.implicitHeight + Style.spacing.rowPaddingX

    Component.onCompleted: root.registerOption(checkRow.optionIndex, checkRow)
    Component.onDestruction: root.unregisterOption(checkRow.optionIndex, checkRow)

    MouseArea {
      id: checkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setOptionCursor(checkRow.optionIndex)
      onClicked: checkRow.toggled()
    }

    Row {
      id: checkContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        id: checkBox
        anchors.verticalCenter: parent.verticalCenter
        text: checkRow.checked ? "" : ""
        color: checkRow.checked ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Text {
        id: checkLabel
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, checkContent.width - checkContent.spacing - checkBox.implicitWidth)
        text: checkRow.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
    }
  }

  // Labelled text setting. Writes on Enter or on losing focus; Esc reverts to
  // the stored value, so a half-typed regex is never what gets saved.
  component SettingText: Column {
    id: settingText
    property string label: ""
    property string description: ""
    property string placeholder: ""
    property string settingKey: ""
    property string value: ""
    property string errorText: ""
    property int optionIndex: -1

    function activate() {
      field.forceActiveFocus()
      field.selectAll()
    }

    spacing: Style.spacing.labelGap

    Component.onCompleted: root.registerOption(settingText.optionIndex, settingText)
    Component.onDestruction: root.unregisterOption(settingText.optionIndex, settingText)

    // Never while the field is focused: rebinding under the cursor would eat
    // whatever the user is halfway through typing.
    onValueChanged: if (!field.activeFocus && field.text !== value) field.text = value

    Text {
      text: settingText.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      visible: settingText.description !== ""
      width: settingText.width
      text: settingText.description
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    TextField {
      id: field
      width: settingText.width
      text: settingText.value
      placeholderText: settingText.placeholder
      foreground: root.foreground
      font.family: root.fontFamily
      hasCursor: root.cursorActive && root.optionIndex === settingText.optionIndex

      onHoveredChanged: if (hovered) root.setOptionCursor(settingText.optionIndex)
      onActiveFocusChanged: root.noteEditorFocus(activeFocus)
      onEditingFinished: if (text !== settingText.value) root.persistSetting(settingText.settingKey, text)
      onAccepted: keyCatcher.forceActiveFocus()

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          field.text = settingText.value
          keyCatcher.forceActiveFocus()
          event.accepted = true
        }
      }
    }

    Text {
      visible: settingText.errorText !== ""
      width: settingText.width
      text: settingText.errorText
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  component SettingNumber: Column {
    id: settingNumber
    property string label: ""
    property string description: ""
    property string settingKey: ""
    property int value: 0
    property int from: 0
    property int to: 999
    property int step: 1
    property int optionIndex: -1

    function activate() { number.field.forceActiveFocus() }

    function adjust(delta) {
      var next = Math.max(settingNumber.from,
                          Math.min(settingNumber.to, settingNumber.value + delta * settingNumber.step))
      if (next !== settingNumber.value) root.persistSetting(settingNumber.settingKey, next)
    }

    spacing: Style.spacing.labelGap

    Component.onCompleted: root.registerOption(settingNumber.optionIndex, settingNumber)
    Component.onDestruction: root.unregisterOption(settingNumber.optionIndex, settingNumber)

    Text {
      text: settingNumber.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      visible: settingNumber.description !== ""
      width: settingNumber.width
      text: settingNumber.description
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    NumberField {
      id: number
      label: ""
      value: settingNumber.value
      from: settingNumber.from
      to: settingNumber.to
      stepSize: settingNumber.step
      foreground: root.foreground
      fontFamily: root.fontFamily
      hasCursor: root.cursorActive && root.optionIndex === settingNumber.optionIndex

      onHovered: function(on) { if (on) root.setOptionCursor(settingNumber.optionIndex) }
      onModified: function(value) { root.persistSetting(settingNumber.settingKey, value) }

      Connections {
        target: number.field
        function onActiveFocusChanged() { root.noteEditorFocus(number.field.activeFocus) }
      }
    }
  }
}
