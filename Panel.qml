import QtQuick
import QtQuick.Controls as Controls
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
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  property double seenThreshold: 0
  readonly property int count: service ? service.centerModel.count : 0
  onCountChanged: if (opened) seenThreshold = Date.now()
  readonly property bool unseen: service && service.centerModel.count > 0
    && service.centerModel.get(0).ts * 1000 > seenThreshold

  onOpenedChanged: {
    if (service) service.centerOpen = opened
    if (opened) seenThreshold = Date.now()
  }
  Component.onDestruction: if (service) service.centerOpen = false

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function clear(): void { if (root.service) root.service.clearCenter() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.host || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(Style.space(500), Style.space(500))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: header
        width: parent.width
        spacing: Style.space(10)
        Item {
          width: parent.width
          height: Math.max(title.implicitHeight, clearButton.implicitHeight)
          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Notifications"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Button {
            id: clearButton
            anchors.right: parent.right
            text: "Clear all"
            enabled: root.service && root.service.centerModel.count > 0
            onClicked: root.service.clearCenter()
          }
        }
        PanelSeparator {}
      }

      Text {
        anchors.centerIn: parent
        visible: !root.service || root.service.centerModel.count === 0
        text: root.service ? "No notifications" : "Notification service unavailable"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      ListView {
        id: list
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        spacing: Style.space(10)
        model: root.service ? root.service.centerModel : null
        Controls.ScrollBar.vertical: Controls.ScrollBar {}

        delegate: Item {
          id: entry
          required property var model
          width: list.width
          height: toast.height

          HoverHandler { id: hover }
          Toast {
            id: toast
            x: Style.space(10)
            cardWidth: entry.width - Style.space(20)
            row: entry.model
            expanded: true
            paused: true
            hovered: hover.hovered
            hoverX: hover.point.position.x
            hoverY: hover.point.position.y
            now: root.service.nowTick
            actions: root.service.actionsOf(row.key, root.service.refsRevision)
            actionsAlign: root.service.actionsAlign
            snoozeOptions: root.service.snoozeOptions
            replying: root.service.replyingKey === row.key
            onActivated: { root.service.activate(row.key); root.close() }
            onDismissed: root.service.dismissCenter(row.key)
            onActionInvoked: function(identifier) { root.service.invokeAction(row.key, identifier) }
            onOfferTaken: function(kind, value) { root.service.takeOffer(kind, value, row.key) }
            onReplyRequested: root.service.replyingKey = row.key
            onReplySent: function(text) { root.service.sendReply(row.key, text) }
            onReplyCancelled: root.service.replyingKey = ""
            onSnoozeRequested: function(seconds) {
              root.service.snoozeSource(row.groupKey, row.source || row.app, seconds)
            }
            onSilenceRequested: root.service.setDoNotDisturb(true)
          }
        }
      }
    }
  }
}
