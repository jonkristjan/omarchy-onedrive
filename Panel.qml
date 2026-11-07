import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// OneDrive status in the bar. Reads a snapshot from status.py (local state
// only: systemd, the client's monitor-status.json, the journal and the sync
// folder) and never talks to the network itself.
Panel {
  id: root
  moduleName: "onedrive"
  ipcTarget: "onedrive"
  manageIpc: false

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string helperPath: pluginDir + "/status.py"
  readonly property string unit: "onedrive.service"
  readonly property int refreshSec: Math.max(5, Math.min(300, Number(setting("refreshIntervalSec", 15))))

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- State --------------------------------------------------------------

  property var snap: ({ ok: false })
  property double nowSec: Date.now() / 1000
  readonly property string status: snap.ok ? String(snap.status || "") : "starting"
  readonly property var st: Model.state(status)
  readonly property var client: snap.client || null
  readonly property var service: snap.service || ({})
  readonly property var folders: snap.folders || []
  readonly property var activity: (snap.activity || []).slice(0, 3)
  readonly property var failures: snap.failures || []
  readonly property bool running: service.active === "active" || service.active === "activating"

  // The switch holds what was asked for until a snapshot agrees (-1: follow
  // the service). Stopping the client can take a minute while it finishes a cycle.
  property int desiredRunning: -1
  readonly property bool powerOn: desiredRunning === -1 ? running : desiredRunning === 1
  readonly property bool powerBusy: desiredRunning !== -1

  readonly property color barIconColor: st.tone === "urgent" ? urgent
    : (st.tone === "dim" || !powerOn) ? Qt.darker(barForeground, 1.55) : barForeground

  readonly property string tooltip: {
    var parts = ["OneDrive", st.label]
    if (client && client.lastSuccessAt && running) parts.push("synced " + Model.ago(client.lastSuccessAt, nowSec))
    return parts.join(" · ")
  }

  property bool _full: false
  property bool _again: false
  function refresh(full) {
    if (pluginDir === "") return
    if (statusProcess.running) { _again = true; _full = _full || full === true; return }
    _full = full === true
    statusProcess.command = ["python3", "-I", root.helperPath].concat(_full ? [] : ["--light"])
    statusProcess.running = true
  }

  function applySnapshot(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) return
    // A light snapshot carries no lists; keep the last full ones.
    if (parsed.activity === undefined && snap.ok) {
      parsed.activity = snap.activity
      parsed.failures = snap.failures
      parsed.folders = snap.folders
      parsed.totals = snap.totals
    }
    snap = parsed
    nowSec = Number(parsed.now) || Date.now() / 1000
    if (desiredRunning !== -1 && running === (desiredRunning === 1)) {
      desiredRunning = -1
      powerDeadline.stop()
    }
  }

  // ---- Actions ------------------------------------------------------------

  function setPower(on) {
    if (powerBusy || powerProcess.running) return
    desiredRunning = on ? 1 : 0
    powerProcess.command = ["systemctl", "--user", on ? "start" : "stop", unit]
    powerProcess.running = true
    powerDeadline.restart()
  }
  function togglePower() { setPower(!powerOn) }

  function restartService() {
    if (powerBusy || powerProcess.running) return
    desiredRunning = 1
    powerProcess.command = ["systemctl", "--user", "restart", unit]
    powerProcess.running = true
    powerDeadline.restart()
  }

  function syncPath(rel) {
    var base = String(snap.syncDir || "")
    if (base === "") return ""
    return rel ? base + "/" + rel : base
  }

  function openPath(rel) {
    var path = syncPath(rel)
    if (path !== "") Quickshell.execDetached(["xdg-open", path])
    root.close()
  }

  // The user's OneDrive web app when status.py found one (any Omarchy web app
  // pointing at OneDrive), otherwise onedrive.live.com as a web app. Focus its
  // window when it is open, otherwise launch it.
  readonly property string webAppUrl: /^https:\/\//.test(String(snap.webAppUrl || "")) ? String(snap.webAppUrl) : "https://onedrive.live.com/"
  function openWeb() {
    // The URL is passed as an argument, never spliced into the script.
    Quickshell.execDetached(["sh", "-c",
      'exec omarchy-launch-or-focus-webapp "$(omarchy-webapp-window-class "$1")" "$1"', "sh", webAppUrl])
    root.close()
  }

  function openLog() {
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.onedrive-log",
                             "journalctl", "--user", "-u", unit, "-f", "-n", "200"])
    root.close()
  }

  // ---- Keyboard cursor ----------------------------------------------------

  property int rowIndex: 0
  property bool cursorActive: false
  readonly property var rows: ["power"].concat(folders.map(function (f, i) { return "folder:" + i }))
    .concat(["open", "web", "log", "restart"])
  readonly property string currentRow: cursorActive ? rows[Math.min(rowIndex, rows.length - 1)] : ""

  function setRowCursor(id) { cursorActive = true; rowIndex = Math.max(0, rows.indexOf(id)) }

  function moveCursor(dy) {
    cursorActive = true
    rowIndex = Math.max(0, Math.min(rows.length - 1, rowIndex + dy))
  }

  function activate(id) {
    if (id === "power") togglePower()
    else if (id.indexOf("folder:") === 0) {
      var f = folders[Number(id.slice(7))]
      if (f) openPath(f.path)
    }
    else if (id === "open") openPath("")
    else if (id === "web") openWeb()
    else if (id === "log") openLog()
    else if (id === "restart") restartService()
  }

  // ---- Wiring -------------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    rowIndex = 0
    panelFlick.contentY = 0
    refresh(true)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Component.onCompleted: refresh(true)

  // omarchy-shell onedrive toggle | refresh | status
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(true); return "ok" }
    function status(): string { return root.status }
  }

  Timer {
    interval: (root.opened || root.powerBusy || root.status === "transferring" ? 3 : root.refreshSec) * 1000
    repeat: true
    running: true
    onTriggered: root.refresh(root.opened)
  }

  Timer {
    id: powerDeadline
    interval: 120000
    onTriggered: { root.desiredRunning = -1; root.refresh(false) }
  }

  Process {
    id: powerProcess
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.desiredRunning = -1; powerDeadline.stop() }
      root.refresh(root.opened)
    }
  }

  Process {
    id: statusProcess
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applySnapshot(statusOut.text)
      if (root._again) { var full = root._full; root._again = false; root.refresh(full) }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.st.glyph
    foreground: root.barIconColor
    tooltipText: root.opened ? "" : root.tooltip
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.openPath("")
      else if (buttonCode === Qt.MiddleButton) root.refresh(true)
      else root.toggle()
    }
  }

  // ---- Popup --------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + Style.space(4), Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activate(root.currentRow)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = t.toLowerCase()
        if (key === "r") root.refresh(true)
        else if (key === "o") root.openPath("")
        else if (key === "l") root.openLog()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        // Inset top and bottom like the sides, so the last row's hover box isn't clipped.
        contentHeight: column.implicitHeight + Style.space(4)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          x: Style.space(2)
          y: Style.space(2)
          width: panelFlick.width - Style.space(4)
          spacing: Style.space(12)

          Hero { width: parent.width }

          // ---- Status ----
          Column {
            visible: root.running && root.client !== null
            width: parent.width
            spacing: Style.space(4)

            InfoRow { label: "Last sync"; value: Model.lastSyncLine(root.client, root.nowSec) }
            InfoRow {
              label: "Connection"
              value: root.client && root.client.reachability === "reachable" ? "Reachable" : "Not reachable"
              warning: root.client && root.client.reachability !== "reachable"
            }
            InfoRow { label: "Running for"; value: root.service.since ? Model.duration(root.nowSec - root.service.since) : "" }
            InfoRow { label: "Memory"; value: Model.memoryLine(root.service) }
          }

          // ---- Problems ----
          PanelSeparator { visible: problems.visible; foreground: root.foreground }
          Column {
            id: problems
            readonly property var cycle: root.client ? root.client.lastCycle : null
            readonly property int failedCount: cycle ? cycle.uploadFailures + cycle.downloadFailures : 0
            visible: root.running && (failedCount > 0 || root.failures.length > 0)
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "FAILED IN LAST SYNC"
              foreground: root.urgent
              fontFamily: root.fontFamily
            }
            Repeater {
              model: root.failures
              FileRow {
                required property var modelData
                glyph: "\u{F0026}"
                name: Model.basename(modelData.path)
                caption: "Failed to " + modelData.direction + " · " + Model.dirname(modelData.path)
                warning: true
                onClicked: root.openPath(Model.dirname(modelData.path))
              }
            }
            PlainText {
              visible: root.failures.length === 0
              text: Model.count(problems.failedCount, "item", "items") + " failed; see the log"
              color: root.urgent
            }
          }

          // ---- Synced folders ----
          PanelSeparator { visible: root.folders.length > 0; foreground: root.foreground }
          Column {
            visible: root.folders.length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "SYNCED FOLDERS" + (root.snap.totals
                ? " · " + Model.count(root.snap.totals.files, "FILE", "FILES") + " · " + Model.bytes(root.snap.totals.bytes)
                : "")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Repeater {
              model: root.folders
              ActionRow {
                required property var modelData
                required property int index
                rowId: "folder:" + index
                glyph: "\u{F024B}"
                label: modelData.path
                hint: Model.count(modelData.files, "file", "files") + " · " + Model.bytes(modelData.bytes)
              }
            }
          }

          // ---- Recent activity ----
          PanelSeparator { visible: root.activity.length > 0; foreground: root.foreground }
          Column {
            visible: root.activity.length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "RECENT ACTIVITY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Repeater {
              model: root.activity
              FileRow {
                required property var modelData
                glyph: Model.activityGlyph(modelData.kind)
                name: Model.basename(modelData.path)
                caption: Model.activityCaption(modelData, root.nowSec)
                warning: modelData.ok === false
                onClicked: root.openPath(Model.dirname(modelData.path))
              }
            }
          }

          // ---- Actions ----
          PanelSeparator { foreground: root.foreground }
          Column {
            width: parent.width
            spacing: Style.space(4)

            ActionRow { rowId: "open"; glyph: "\u{F0770}"; label: "Open OneDrive folder"; hint: "O" }
            ActionRow { rowId: "web"; glyph: "\u{F059F}"; label: "Open OneDrive web app" }
            ActionRow { rowId: "log"; glyph: "\u{F0219}"; label: "View log"; hint: "L" }
            ActionRow { rowId: "restart"; glyph: "\u{F0709}"; label: "Restart service"; visible: root.running }
          }
        }
      }
    }
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.nowSec = Date.now() / 1000
  }

  // ---- Components ---------------------------------------------------------

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component Hero: Item {
    id: hero
    implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

    PlainText {
      id: heroIcon
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: root.st.glyph
      font.pixelSize: Style.font.display
      color: root.st.tone === "urgent" ? root.urgent : root.foreground
      opacity: root.powerOn ? 1.0 : 0.5
      elide: Text.ElideNone
    }

    ToggleSwitch {
      id: powerSwitch
      checked: root.powerOn
      busy: root.powerBusy
      hasCursor: root.currentRow === "power"
      foreground: root.foreground
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      onHovered: function(on) { if (on) root.setRowCursor("power") }
      onToggled: root.togglePower()

      PanelToolTip {
        visible: powerSwitch.containsMouse
        text: root.powerOn ? "Stop the OneDrive service" : "Start the OneDrive service"
        fontFamily: root.fontFamily
      }
    }

    Column {
      id: heroLabels
      anchors.left: heroIcon.right
      anchors.leftMargin: Style.space(14)
      anchors.right: powerSwitch.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      PlainText {
        width: parent.width
        text: "OneDrive"
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      PlainText {
        width: parent.width
        text: (root.powerBusy ? (root.powerOn ? "Starting" : "Stopping") : root.st.label).toUpperCase()
        color: root.st.tone === "urgent" ? root.urgent : Qt.darker(root.foreground, 1.4)
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
      }
    }
  }

  // "Last sync                3m ago · took 4m 42s"
  component InfoRow: Item {
    id: info
    property string label: ""
    property string value: ""
    property bool warning: false
    width: parent ? parent.width : implicitWidth
    implicitHeight: infoLabel.implicitHeight
    visible: value !== ""

    PlainText {
      id: infoLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      text: info.label
    }
    PlainText {
      anchors.left: infoLabel.right
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      horizontalAlignment: Text.AlignRight
      text: info.value
      color: info.warning ? root.urgent : root.dim
    }
  }

  // A file in the activity or failure list; a click opens its folder.
  component FileRow: CursorSurface {
    id: fileRow
    property string glyph: ""
    property string name: ""
    property string caption: ""
    property bool warning: false
    signal clicked()

    width: parent ? parent.width : implicitWidth
    hasCursor: fileMouse.containsMouse
    foreground: root.foreground
    implicitHeight: fileContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: fileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.cursorActive = false
      onClicked: fileRow.clicked()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      PlainText {
        text: fileRow.glyph
        color: fileRow.warning ? root.urgent : root.foreground
        font.pixelSize: Style.font.icon
        elide: Text.ElideNone
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: fileContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        PlainText {
          Layout.fillWidth: true
          text: fileRow.name
          elide: Text.ElideMiddle
        }
        PlainText {
          Layout.fillWidth: true
          visible: text !== ""
          text: fileRow.caption
          color: fileRow.warning ? root.urgent : root.dim
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property string rowId: ""
    property string glyph: ""
    property string label: ""
    property string hint: ""

    width: parent ? parent.width : implicitWidth
    hasCursor: root.currentRow === rowId
    foreground: root.foreground
    implicitHeight: actionLabel.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setRowCursor(actionRow.rowId)
      onClicked: root.activate(actionRow.rowId)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      PlainText {
        text: actionRow.glyph
        font.pixelSize: Style.font.icon
        elide: Text.ElideNone
        Layout.alignment: Qt.AlignVCenter
      }
      PlainText {
        id: actionLabel
        Layout.fillWidth: true
        text: actionRow.label
      }
      PlainText {
        visible: actionRow.hint !== ""
        text: actionRow.hint
        color: root.dim
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideNone
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
