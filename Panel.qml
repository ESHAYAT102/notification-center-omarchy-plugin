import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "esh.notification-center"
  ipcTarget: "esh.notification-center"
  manageIpc: false

  property var anchorItem: null
  property var host: null

  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor("omarchy.notifications") : null
  readonly property string stateDir: service && service.popupStateDir
    ? service.popupStateDir
    : (Quickshell.env("HOME") + "/.local/state/omarchy/notifications/")
  readonly property string historyDir: stateDir + "history/"
  readonly property string imagesDir: stateDir + "images/"
  readonly property color foreground: Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var historyEntries: []
  property bool historyLoaded: false
  property bool historyReadPending: false
  property real seenThreshold: 0

  property ListModel displayModel: ListModel { id: displayModel }

  readonly property int liveCount: service && service.popupModel ? service.popupModel.count : 0
  readonly property bool unseen: {
    if (root.liveCount > 0) return true
    for (var i = 0; i < historyEntries.length; i++) {
      if (historyEntries[i].timestamp > root.seenThreshold) return true
    }
    return false
  }

  function open() {
    root.controller.show()
    if (!historyLoaded) readHistory()
    else root.refreshModel()
    root.markSeen()
  }

  function close() {
    root.controller.hide()
  }

  function markSeen() {
    var newest = 0
    for (var i = 0; i < historyEntries.length; i++) {
      var t = Number(historyEntries[i].timestamp || 0)
      if (t > newest) newest = t
    }
    root.seenThreshold = newest
  }

  function toggle() {
    root.opened ? root.close() : root.open()
  }

  function readHistory() {
    if (historyProc.running) {
      historyReadPending = true
      return
    }
    historyProc.command = ["bash", "-c", "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", root.historyDir]
    historyProc.running = true
  }

  function parseHistory(raw) {
    var lines = String(raw || "").split("\n")
    var entries = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      try {
        var v = JSON.parse(line)
        if (v && typeof v === "object") entries.push(v)
      } catch (e) {
      }
    }
    entries.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
    historyEntries = entries
    historyLoaded = true
    root.refreshModel()
    if (root.opened) root.markSeen()
  }

  function refreshModel() {
    displayModel.clear()
    var pm = root.service && root.service.popupModel ? root.service.popupModel : null
    if (pm) {
      for (var i = 0; i < pm.count; i++) {
        var row = pm.get(i)
        displayModel.append({
          kind: "live", srcIndex: i,
          app: row.app || "", appIcon: row.appIcon || "", summary: row.summary || "",
          body: row.body || "", image: row.image || "", glyph: row.glyph || "",
          exec: row.exec || "", urgency: row.urgency || 0,
          originalId: row.originalId || 0, timestamp: row.timestamp || 0
        })
      }
    }
    for (var j = 0; j < historyEntries.length; j++) {
      var h = historyEntries[j]
      displayModel.append({
        kind: "history", srcIndex: -1,
        app: h.app || "", appIcon: h.appIcon || "", summary: h.summary || "",
        body: h.body || "", image: h.image || "", glyph: h.glyph || "",
        exec: h.exec || "", urgency: h.urgency || 0,
        originalId: h.originalId || h.id || 0, timestamp: h.timestamp || 0
      })
    }
  }

  function liveIndexFor(originalId, timestamp) {
    var pm = root.service && root.service.popupModel ? root.service.popupModel : null
    if (!pm) return -1
    for (var i = 0; i < pm.count; i++) {
      var row = pm.get(i)
      if (row.originalId === originalId && row.timestamp === timestamp) return i
    }
    return -1
  }

  function actOnRow(index) {
    var entry = displayModel.get(index)
    if (!entry) return
    if (entry.kind === "live") {
      var li = root.liveIndexFor(entry.originalId, entry.timestamp)
      if (li >= 0 && root.service) root.service.invokePopupDefault(li)
      return
    }
    if (entry.exec) Util.execDetached(entry.exec)
    else if (root.service && typeof root.service.focusApp === "function" && entry.app)
      root.service.focusApp({ app: entry.app })
    root.removeHistoryEntry(index)
  }

  function dismissRow(index) {
    var entry = displayModel.get(index)
    if (!entry) return
    if (entry.kind === "live") {
      var li = root.liveIndexFor(entry.originalId, entry.timestamp)
      if (li >= 0 && root.service) root.service.dismissPopup(li)
      return
    }
    root.removeHistoryEntry(index)
  }

  function removeHistoryEntry(index) {
    var entry = displayModel.get(index)
    if (!entry) return
    var stem = String(entry.timestamp || 0) + "-" + String(entry.originalId || 0)
    var script = "stem=" + Util.shellQuote(stem) + "\n"
      + "hist=" + Util.shellQuote(root.historyDir) + "\n"
      + "imgs=" + Util.shellQuote(root.imagesDir) + "\n"
      + "rm -f -- \"$hist/$stem.json\" \"$imgs/$stem\"-*\n"
    Util.execDetached(script)
    var out = []
    for (var i = 0; i < historyEntries.length; i++) {
      var h = historyEntries[i]
      if (String(h.timestamp || 0) + "-" + String(h.originalId || 0) !== stem) out.push(h)
    }
    historyEntries = out
    root.refreshModel()
  }

  function clearAll() {
    if (root.service) {
      root.service.clearPopups()
      root.service.clearHistory()
    }
    historyEntries = []
    historyLoaded = true
    root.readHistory()
  }

  function relativeTime(ts) {
    var n = Number(ts || 0)
    if (!n) return ""
    var diff = Math.max(0, Date.now() - n)
    var min = Math.floor(diff / 60000)
    if (min < 1) return "just now"
    if (min < 60) return min + "m ago"
    var hr = Math.floor(min / 60)
    if (hr < 24) return hr + "h ago"
    var d = Math.floor(hr / 24)
    if (d < 7) return d + "d ago"
    var date = new Date(n)
    return (date.getMonth() + 1) + "/" + date.getDate()
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  function sanitizeBody(body, app, appIcon) {
    var text = String(body || "").replace(/<img[^>]*>/gi, "")
    var source = (String(app || "") + "\n" + String(appIcon || "")).toLowerCase()
    if (source.indexOf("chrom") < 0 && source.indexOf("brave") < 0
        && source.indexOf("vivaldi") < 0 && source.indexOf("microsoft-edge") < 0
        && source.indexOf("opera") < 0) return text
    return text
      .replace(/^\s*<a\b[^>]*>\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/[^<\s]*)?\s*<\/a>\s*/i, "")
      .replace(/^\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/\S*)?\s+/i, "")
  }

  onOpenedChanged: {
    if (root.opened) {
      if (!historyLoaded || historyReadPending) readHistory()
      else refreshTimer.restart()
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
  }

  Timer {
    id: refreshTimer
    interval: 150
    repeat: false
    onTriggered: root.refreshModel()
  }

  Timer {
    id: periodicTimer
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.readHistory()
  }

  property int lastLiveCount: -1

  Timer {
    id: livePoll
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: {
      var n = root.service && root.service.popupModel ? root.service.popupModel.count : 0
      if (n !== root.lastLiveCount) {
        root.lastLiveCount = n
        root.readHistory()
      }
    }
  }

  Process {
    id: historyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseHistory(text)
    }
    onExited: function() {
      if (root.historyReadPending) {
        root.historyReadPending = false
        root.readHistory()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.host || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(Style.space(500), Style.space(500))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.readHistory()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(10)

          Item {
            id: headerRow
            width: parent.width
            height: Math.max(headerTitle.implicitHeight, headerControls.implicitHeight)

            Text {
              id: headerTitle
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              text: "Notifications"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Row {
              id: headerControls
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)

              Text {
                id: clearText
                text: "Clear all"
                visible: root.displayModel.count > 0
                color: clearHover.hovered ? Style.hoverStateColor(root.foreground, Color.accent) : Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  id: clearHover
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.clearAll()
                }
              }
            }
          }

          PanelSeparator {}

          Item {
            id: emptyState
            width: parent.width
            implicitHeight: Style.space(72)
            visible: root.displayModel.count === 0

            Text {
              anchors.centerIn: parent
              text: "No notifications"
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Repeater {
            model: root.displayModel
            delegate: rowComponent
          }
        }
      }
    }
  }

  Component {
    id: rowComponent

    Item {
      id: row
      required property var model
      width: parent ? parent.width : 0

      readonly property int iconSize: Style.space(26)
      readonly property int rowPad: Style.space(6)
      readonly property color rowForeground: root.foreground

      height: Math.max(iconSize + rowPad * 2, textColumn.implicitHeight + rowPad * 2)

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: rowHover.hovered ? Style.hoverFillFor(row.rowForeground, Color.accent) : "transparent"
      }

      MouseArea {
        id: rowHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.actOnRow(row.model.index)
      }

      Item {
        id: iconSlot
        width: row.iconSize
        height: row.iconSize
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter

        Image {
          id: rowIcon
          anchors.fill: parent
          source: root.iconSource(row.model.image ? row.model.image : row.model.appIcon)
          fillMode: Image.PreserveAspectFit
          sourceSize.width: width * Screen.devicePixelRatio
          sourceSize.height: height * Screen.devicePixelRatio
          visible: status === Image.Ready
        }

        Text {
          id: rowGlyph
          anchors.centerIn: parent
          text: row.model.glyph ? row.model.glyph : "\uf0f3"
          color: row.rowForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          visible: !rowIcon.visible
        }
      }

      Column {
        id: textColumn
        anchors.left: iconSlot.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: dismissArea.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          id: summaryText
          width: parent.width
          text: row.model.summary
          color: row.model.urgency === 2 ? Color.urgent : row.rowForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          maximumLineCount: 1
        }

        Text {
          id: bodyText
          width: parent.width
          text: root.sanitizeBody(row.model.body, row.model.app, row.model.appIcon)
          visible: text.length > 0
          color: Util.alpha(row.rowForeground, 0.75)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          maximumLineCount: 2
          wrapMode: Text.Wrap
        }

        Text {
          id: metaText
          width: parent.width
          text: (row.model.app ? row.model.app : "Notification")
            + (root.relativeTime(row.model.timestamp) ? "  ·  " + root.relativeTime(row.model.timestamp) : "")
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          maximumLineCount: 1
        }
      }

      Item {
        id: dismissArea
        width: row.iconSize
        height: row.iconSize
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: dismissHover.hovered ? Style.hoverFillFor(row.rowForeground, Color.accent) : "transparent"
        }

        Text {
          anchors.centerIn: parent
          text: "\uf00d"
          color: dismissHover.hovered ? row.rowForeground : Qt.darker(row.rowForeground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: dismissHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.dismissRow(row.model.index)
        }
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: Util.alpha(row.rowForeground, 0.08)
      }
    }
  }
}
