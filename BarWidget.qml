import QtQuick
import qs.Commons
import qs.Ui

// Bar entry point: a YouTube glyph that dims when nothing is playing.
// Left click opens the panel, middle click pauses/resumes, right click
// starts/stops the saved video.
BarWidget {
  id: root
  moduleName: "ronholt.youtube-background"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(root.moduleName) : null
  readonly property string status: service ? service.status : "stopped"
  readonly property bool active: status === "playing" || status === "starting"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("service" in target) target.service = root.service
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰗃"
    slotSize: Style.bar.iconSlot
    opacity: root.active ? 1.0 : (root.status === "paused" ? 0.75 : 0.45)
    tooltipText: ""

    Behavior on opacity { NumberAnimation { duration: 160 } }

    onPressed: function(b) {
      if (!root.service) { root.togglePanel(); return }
      if (b === Qt.RightButton) root.service.toggle()
      else if (b === Qt.MiddleButton) root.service.togglePause()
      else root.togglePanel()
    }
  }
}
