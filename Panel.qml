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
  // reads the service's on-disk storage directly. Rows the service replays
  // (and its empty-history placeholder) are copied here and immediately
  // dismissed from popupModel, so history is only ever shown inside the
  // panel and never flashes past as an OSD toast.
  property ListModel displayModel: ListModel { id: displayModel }
  property real seenThreshold: 0
  property var dismissedKeys: ({})
  // Live notifications are removed from the toast model just before their UI
  // timer expires. This keeps the sender's action object alive for the center
  // without leaving the toast visible indefinitely.
  property var heldKeys: ({})
  property var heldRefs: ({})
  property var liveRowRefs: ({})
  property var rowRemaining: ({})
  property var rowLastTick: ({})
  property bool refreshDeferred: false
  property bool discardReplay: false
  // True from the first panel open until the next shell restart. It is what
  // separates rows replayed on our request from toasts restored at startup,
  // which must keep their place on screen until the panel is actually open.
  property bool replayPending: false

  readonly property int modelCount: service && service.popupModel ? service.popupModel.count : 0

  onModelCountChanged: root.syncFromModel()
  readonly property bool unseen: {
    for (var i = 0; i < root.displayModel.count; i++) {
      var displayed = root.displayModel.get(i)
      if (displayed && Number(displayed.timestamp || 0) > root.seenThreshold) return true
    }
    if (!root.service || !root.service.popupModel) return false
    for (var j = 0; j < root.service.popupModel.count; j++) {
      var row = root.service.popupModel.get(j)
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
  // expose the direct method. syncFromModel absorbs the replayed rows the
  // moment they land, so they never flash past as OSD toasts.
  function refreshFromService() {
    // Replaying history clears popupModel and dismisses its live Notification
    // objects. Keep those objects alive so their browser/app actions still
    // exist when a row in this panel is clicked.
    if (root.hasLivePopups()) {
      root.refreshDeferred = true
      return
    }
    root.refreshDeferred = false
    root.replayPending = true
    if (root.service && typeof root.service.showRecentHistory === "function") {
      root.service.showRecentHistory()
      return
    }
    historyIpcProc.command = ["omarchy-shell", "notifications", "showHistory"]
    historyIpcProc.running = true
  }

  function rowKey(originalId, timestamp) {
    return String(originalId) + ":" + String(timestamp)
  }

  function hasRow(originalId, timestamp) {
    return root.displayIndexFor(originalId, timestamp) >= 0
  }

  function displayIndexFor(originalId, timestamp) {
    var key = root.rowKey(originalId, timestamp)
    for (var i = 0; i < root.displayModel.count; i++) {
      if (root.rowKey(root.displayModel.get(i).originalId, root.displayModel.get(i).timestamp) === key) return i
    }
    return -1
  }

  function appendRow(row, newest, live) {
    if (!row || row.originalId < 0) return
    var key = root.rowKey(row.originalId, row.timestamp)
    if (root.dismissedKeys[key]) return
    var snapshot = {
      id: row.id || row.originalId || 0,
      app: row.app || "", appIcon: row.appIcon || "", summary: row.summary || "",
      body: row.body || "", image: row.image || "", glyph: row.glyph || "",
      exec: row.exec || "", urgency: row.urgency || 0,
      expireTimeout: row.expireTimeout || 0,
      originalId: row.originalId || 0, timestamp: row.timestamp || 0
    }
    if (newest) root.displayModel.insert(0, snapshot)
    else root.displayModel.append(snapshot)
    if (live) {
      root.liveRowRefs[key] = root.service && root.service.liveRefs
        ? root.service.liveRefs[row.originalId] : null
      root.rowRemaining[key] = 1.0
      root.rowLastTick[key] = Date.now()
    }
  }

  function updateLiveRow(index, row) {
    if (index < 0 || !row) return false
    var current = root.displayModel.get(index)
    var lifetimeChanged = current.summary !== String(row.summary || "")
      || current.body !== String(row.body || "")
      || current.image !== String(row.image || "")
    var changed = current.app !== String(row.app || "")
      || current.appIcon !== String(row.appIcon || "")
      || lifetimeChanged
      || current.glyph !== String(row.glyph || "")
      || current.exec !== String(row.exec || "")
      || Number(current.urgency || 0) !== Number(row.urgency || 0)
      || Number(current.expireTimeout || 0) !== Number(row.expireTimeout || 0)
    var values = {
      app: String(row.app || ""), appIcon: String(row.appIcon || ""),
      summary: String(row.summary || ""), body: String(row.body || ""),
      image: String(row.image || ""), glyph: String(row.glyph || ""),
      exec: String(row.exec || ""), urgency: Number(row.urgency || 0),
      expireTimeout: Number(row.expireTimeout || 0)
    }
    for (var role in values) root.displayModel.setProperty(index, role, values[role])
    if (lifetimeChanged) {
      var key = root.rowKey(row.originalId, row.timestamp)
      root.rowRemaining[key] = 1.0
      root.rowLastTick[key] = Date.now()
    }
    return changed
  }

  // Mirror popupModel into the panel. Rows the service replays on request
  // (replayPending) and its empty-history placeholder are absorbed: copied,
  // then dismissed from the service model so they never surface as toasts.
  // Toasts restored at startup are only absorbed once the panel is opened,
  // and live toasts are reflected but stay on screen where they belong.
  function syncFromModel() {
    if (!root.service || !root.service.popupModel) return
    var pm = root.service.popupModel
    for (var i = 0; i < pm.count; i++) {
      var row = pm.get(i)
      if (!row) continue
      if (row.originalId < 0) {
        // The "no recent notifications" placeholder: kill it before the toast
        // layer can paint it.
        root.service.dismissPopup(i)
        if (root.discardReplay) discardReplayTimer.restart()
        else root.replayPending = false
        i--
        continue
      }
      var restored = typeof root.service.isRestoredRow === "function"
        && root.service.isRestoredRow(row)
      if (restored) {
        if (root.discardReplay && root.replayPending) {
          root.service.dismissPopup(i)
          discardReplayTimer.restart()
          i--
          continue
        }
        if (root.opened || root.replayPending) {
          if (!root.hasRow(row.originalId, row.timestamp)) root.appendRow(row)
          root.service.dismissPopup(i)
          root.replayPending = false
          i--
        }
      } else {
        var displayIndex = root.displayIndexFor(row.originalId, row.timestamp)
        if (displayIndex < 0) root.appendRow(row, true, true)
        else root.updateLiveRow(displayIndex, row)
        // A notification can arrive while the asynchronous history read is
        // in flight. Detach actionable rows before replayHistory clears the
        // service model, preserving their sender-owned action objects.
        if (root.replayPending && root.holdPopup(i, row)) i--
      }
    }
  }

  function holdExpiringPopups() {
    var pm = root.service && root.service.popupModel ? root.service.popupModel : null
    if (!pm) return
    var now = Date.now()
    for (var i = pm.count - 1; i >= 0; i--) {
      var row = pm.get(i)
      if (!row || row.originalId < 0) continue
      var restored = typeof root.service.isRestoredRow === "function"
        && root.service.isRestoredRow(row)
      if (restored) continue
      var duration = typeof root.service.durationFor === "function"
        ? Number(root.service.durationFor(row.urgency, row.expireTimeout)) : 8000
      var key = root.rowKey(row.originalId, row.timestamp)
      if (duration <= 0) {
        root.rowLastTick[key] = now
        continue
      }
      var lastTick = root.rowLastTick[key] === undefined
        ? now : Number(root.rowLastTick[key])
      var remaining = root.rowRemaining[key] === undefined
        ? 1.0 : Number(root.rowRemaining[key])
      remaining -= Math.max(0, now - lastTick) / duration
      root.rowLastTick[key] = now
      root.rowRemaining[key] = remaining
      // The stock timer advances every 50 ms. A 500 ms margin avoids racing
      // its final tick while preserving almost the full toast lifetime.
      if (remaining * duration > 500) continue
      root.holdPopup(i, row)
    }
    root.trimHeldRows()
    root.trimDisplayRows()
  }

  function holdPopup(index, row) {
    if (!row || !root.service || !root.service.popupModel) return false
    var key = root.rowKey(row.originalId, row.timestamp)
    var ref = root.liveRowRefs[key]
    if (!root.defaultActionFor(ref)) return false
    if (!root.hasRow(row.originalId, row.timestamp)) root.appendRow(row, true, true)
    root.heldKeys[key] = true
    root.heldRefs[key] = ref
    root.forgetLiveKey(key)
    root.service.popupModel.remove(index)
    return true
  }

  function defaultActionFor(ref) {
    try {
      if (!ref || !ref.actions) return null
      for (var i = 0; i < ref.actions.length; i++) {
        var action = ref.actions[i]
        if (action && action.identifier === "default") return action
      }
    } catch (error) {}
    return null
  }

  function syncHeldRows() {
    if (!root.service || typeof root.service.snapshotOf !== "function") return
    for (var i = 0; i < root.displayModel.count; i++) {
      var entry = root.displayModel.get(i)
      var key = root.rowKey(entry.originalId, entry.timestamp)
      if (!root.heldKeys[key]) continue
      var ref = root.heldRefs[key]
      var updated = null
      try {
        if (ref && ref.tracked) updated = root.service.snapshotOf(ref)
      } catch (error) {}
      if (!updated) {
        root.releaseHeld(entry, "closed")
        continue
      }
      updated.originalId = entry.originalId
      updated.timestamp = entry.timestamp
      if (root.updateLiveRow(i, updated)
          && typeof root.service.persistPopupFile === "function")
        root.service.persistPopupFile(updated)
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

  function hasLivePopups() {
    var pm = root.service && root.service.popupModel ? root.service.popupModel : null
    if (!pm) return false
    for (var i = 0; i < pm.count; i++) {
      var row = pm.get(i)
      if (!row || row.originalId < 0) continue
      var restored = typeof root.service.isRestoredRow === "function"
        && root.service.isRestoredRow(row)
      if (!restored) return true
    }
    return false
  }

  function forgetHeldKey(key) {
    if (root.heldKeys[key]) delete root.heldKeys[key]
    if (root.heldRefs[key]) delete root.heldRefs[key]
    root.forgetLiveKey(key)
  }

  function forgetLiveKey(key) {
    delete root.liveRowRefs[key]
    delete root.rowRemaining[key]
    delete root.rowLastTick[key]
  }

  function releaseHeld(entry, reason) {
    if (!entry || !root.service) return false
    var key = root.rowKey(entry.originalId, entry.timestamp)
    if (!root.heldKeys[key]) return false
    var ref = root.heldRefs[key]
    try {
      if (typeof root.service.archivePopupFileFor === "function")
        root.service.archivePopupFileFor(entry)
    } catch (error) {}
    if (reason !== "closed" && ref) {
      try {
        if (ref.tracked) {
          if (reason === "expire" && typeof ref.expire === "function") ref.expire()
          else ref.dismiss()
        }
      } catch (error) {}
    }
    if (root.service.liveRefs && root.service.liveRefs[entry.originalId] === ref)
      delete root.service.liveRefs[entry.originalId]
    root.forgetHeldKey(key)
    return true
  }

  function invokeHeldDefault(entry) {
    if (!entry || !root.service) return false
    var key = root.rowKey(entry.originalId, entry.timestamp)
    if (!root.heldKeys[key]) return false
    var ref = root.heldRefs[key]
    var action = root.defaultActionFor(ref)
    if (!action) return false

    var invoked = false
    try {
      action.invoke()
      invoked = true
    } catch (error) {}
    root.releaseHeld(entry, "dismiss")
    return invoked
  }

  function trimHeldRows() {
    var limit = root.service ? Number(root.service.historyLimit || 10) : 10
    var held = []
    for (var i = 0; i < root.displayModel.count; i++) {
      var entry = root.displayModel.get(i)
      if (root.heldKeys[root.rowKey(entry.originalId, entry.timestamp)]) held.push(entry)
    }
    held.sort(function(a, b) { return Number(b.timestamp || 0) - Number(a.timestamp || 0) })
    for (var j = limit; j < held.length; j++) root.releaseHeld(held[j], "expire")
  }

  function trimDisplayRows() {
    var limit = root.service ? Number(root.service.historyLimit || 10) : 10
    for (var i = root.displayModel.count - 1; i >= 0; i--) {
      var entry = root.displayModel.get(i)
      var key = root.rowKey(entry.originalId, entry.timestamp)
      if (!root.heldKeys[key] && root.liveIndexFor(entry.originalId, entry.timestamp) < 0) {
        root.forgetLiveKey(key)
        if (root.displayModel.count > limit) root.displayModel.remove(i)
      }
    }
  }

  function removeActivatedRow(originalId, timestamp) {
    var key = root.rowKey(originalId, timestamp)
    root.dismissedKeys[key] = true
    root.forgetLiveKey(key)
    // Let the row MouseArea finish its click before destroying its delegate;
    // otherwise the release can fall through to the panel's dismiss overlay.
    Qt.callLater(function() {
      var index = root.displayIndexFor(originalId, timestamp)
      if (index >= 0) root.displayModel.remove(index)
    })
  }

  function actOnRow(index) {
    var entry = root.displayModel.get(index)
    if (!entry) return

    // A live Notification object owns the action registered by the sender.
    // Use the service API while that object still exists; there is no
    // org.freedesktop.Notifications InvokeAction method to call afterward.
    var li = root.liveIndexFor(entry.originalId, entry.timestamp)
    if (li < 0 && root.heldKeys[root.rowKey(entry.originalId, entry.timestamp)]) {
      if (root.invokeHeldDefault(entry)) {
        root.removeActivatedRow(entry.originalId, entry.timestamp)
        return
      }
      root.releaseHeld(entry, "dismiss")
    }
    if (li >= 0 && root.service && typeof root.service.invokePopupDefault === "function") {
      root.forgetLiveKey(root.rowKey(entry.originalId, entry.timestamp))
      root.service.invokePopupDefault(li)
      root.removeActivatedRow(entry.originalId, entry.timestamp)
      return
    }

    if (entry.exec) {
      Util.execDetached(entry.exec)
      root.removeActivatedRow(entry.originalId, entry.timestamp)
      return
    }

    var body = String(entry.body || "")
    var urlMatch = body.match(/https?:\/\/[^\s<>"]+/)
    if (urlMatch) {
      Util.execDetached("xdg-open " + Util.shellQuote(urlMatch[0]))
      root.removeActivatedRow(entry.originalId, entry.timestamp)
      return
    }

    root.focusAppEntry(entry)
    root.removeActivatedRow(entry.originalId, entry.timestamp)
  }

  function focusAppEntry(entry) {
    if (!entry || !entry.app) return
    var shellPath = Quickshell.env("OMARCHY_PATH")
    focusProc.command = [
      shellPath ? shellPath + "/bin/omarchy-hyprland-focus-app" : "omarchy-hyprland-focus-app",
      String(entry.app)
    ]
    focusProc.running = true
  }

  function dismissRow(index) {
    var entry = root.displayModel.get(index)
    if (!entry) return
    if (root.releaseHeld(entry, "dismiss")) {
      root.displayModel.remove(index)
      return
    }
    var li = root.liveIndexFor(entry.originalId, entry.timestamp)
    if (li >= 0 && root.service && !root.service.isRestoredRow(root.service.popupModel.get(li))
        && typeof root.service.dismissPopup === "function") {
      root.forgetLiveKey(root.rowKey(entry.originalId, entry.timestamp))
      root.service.dismissPopup(li)
    } else {
      // A history row has no live counterpart to dismiss; forget it for the
      // rest of this session so a later replay can't resurrect it.
      root.dismissedKeys[root.rowKey(entry.originalId, entry.timestamp)] = true
    }
    root.displayModel.remove(index)
  }

  // Dismiss the on-screen toasts (the service archives them to history), then
  // wipe the recorded history through the public notifications IPC.
  function clearAll() {
    root.refreshDeferred = false
    root.discardReplay = root.replayPending
    for (var i = root.displayModel.count - 1; i >= 0; i--) {
      var held = root.displayModel.get(i)
      root.releaseHeld(held, "dismiss")
    }
    root.displayModel.clear()
    root.dismissedKeys = {}
    root.heldKeys = {}
    root.heldRefs = {}
    root.liveRowRefs = {}
    root.rowRemaining = {}
    root.rowLastTick = {}
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
      root.syncFromModel()
      root.refreshFromService()
      root.markSeen()
    }
  }

  // Drive absorption from the model's own count signal. A binding on
  // service.popupModel.count through the var-typed `service` property is not
  // guaranteed to re-evaluate, which let the empty-history placeholder slip
  // through as an OSD toast.
  Connections {
    target: root.service ? root.service.popupModel : null
    function onCountChanged() { root.syncFromModel() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function clear() { root.clearAll() }
    function invokeLatest(): string {
      if (root.displayModel.count === 0) return "none"
      root.actOnRow(0)
      return "ok"
    }
  }

  Timer {
    id: livePoll
    interval: 100
    running: true
    repeat: true
    onTriggered: {
      root.syncFromModel()
      root.holdExpiringPopups()
      root.syncHeldRows()
      root.trimDisplayRows()
      if (root.opened && root.refreshDeferred && !root.hasLivePopups())
        root.refreshFromService()
    }
  }

  Timer {
    id: discardReplayTimer
    interval: 250
    onTriggered: {
      root.discardReplay = false
      root.replayPending = false
    }
  }

  // The replay batch lands asynchronously (a directory read). onModelCountChanged
  // already fires for each row as it is inserted, so no extra polling is needed.
  Process {
    id: historyIpcProc
    running: false
  }

  Process {
    id: focusProc
    running: false
  }

  Process {
    id: clearIpcProc
    running: false
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
          root.syncFromModel()
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
