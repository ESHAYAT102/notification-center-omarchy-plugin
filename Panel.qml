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
  readonly property color foreground: Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The panel renders a filtered copy of the notifications service's
  // popupModel. Persisted history is replayed into that model through the
  // service itself (the stock `showHistory` IPC route), so this plugin never
  // reads the service's on-disk storage directly.
  property ListModel displayModel: ListModel { id: displayModel }
  property real seenThreshold: 0
  property int lastModelCount: -1

  readonly property int modelCount: service && service.popupModel ? service.popupModel.count : 0
  readonly property bool unseen: {
    if (!root.service || !root.service.popupModel) return false
    for (var i = 0; i < root.service.popupModel.count; i++) {
      var row = root.service.popupModel.get(i)
      if (row && row.originalId >= 0 && Number(row.timestamp || 0) > root.seenThreshold) return true
    }
    return false
  }

  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    root.opened ? root.close() : root.open()
  }

  function markSeen() {
    root.seenThreshold = Date.now()
  }

  // Ask the notifications service to replay its persisted history into
  // popupModel. Falls back to the public IPC when the service does not
  // expose the direct method.
  function refreshFromService() {
    if (root.service && typeof root.service.showRecentHistory === "function") {
      root.service.showRecentHistory()
      return
    }
    historyIpcProc.command = ["omarchy-shell", "notifications", "showHistory"]
    historyIpcProc.running = true
  }

  function refreshModel() {
    displayModel.clear()
    var pm = root.service && root.service.popupModel ? root.service.popupModel : null
    if (!pm) return
    for (var i = 0; i < pm.count; i++) {
      var row = pm.get(i)
      // Skip the service's "no recent notifications" placeholder row.
      if (!row || row.originalId < 0) continue
      displayModel.append({
        app: row.app || "", appIcon: row.appIcon || "", summary: row.summary || "",
        body: row.body || "", image: row.image || "", glyph: row.glyph || "",
        exec: row.exec || "", urgency: row.urgency || 0,
        originalId: row.originalId || 0, timestamp: row.timestamp || 0
      })
    }
  }

  function liveIndexFor(originalId, timestamp) {
    var pm = root.service && root.service.popupModel ? root.service.popupModel : null
    if (!pm) return -1
    for (var i = 0; i < pm.count; i++) {
      var row = pm.get(i)
      if (row && row.originalId === originalId && row.timestamp === timestamp) return i
    }
    return -1
  }

  function actOnRow(index) {
    var entry = displayModel.get(index)
    if (!entry || !root.service) return
    var li = root.liveIndexFor(entry.originalId, entry.timestamp)
    if (li >= 0 && typeof root.service.invokePopupDefault === "function")
      root.service.invokePopupDefault(li)
  }

  function dismissRow(index) {
    var entry = displayModel.get(index)
    if (!entry || !root.service) return
    var li = root.liveIndexFor(entry.originalId, entry.timestamp)
    if (li >= 0 && typeof root.service.dismissPopup === "function")
      root.service.dismissPopup(li)
  }

  // Dismiss the on-screen toasts (the service archives them to history), then
  // wipe the recorded history through the public notifications IPC.
  function clearAll() {
    if (root.service && typeof root.service.clearPopups === "function")
      root.service.clearPopups()
    var shellPath = Quickshell.env("OMARCHY_PATH")
    clearIpcProc.command = [
      shellPath ? shellPath + "/bin/omarchy-shell" : "omarchy-shell",
      "notifications", "clear"
    ]
    clearIpcProc.running = true
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
      root.lastModelCount = root.modelCount
      root.refreshFromService()
      root.refreshModel()
      root.markSeen()
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
    id: livePoll
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: {
      var n = root.modelCount
      if (n !== root.lastModelCount) {
        root.lastModelCount = n
        root.refreshModel()
      }
    }
  }

  Process {
    id: historyIpcProc
    running: false
  }

  Process {
    id: clearIpcProc
    running: false
    onExited: root.refreshModel()
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
        if (t === "r" || t === "R") {
          root.refreshFromService()
          root.refreshModel()
        }
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
