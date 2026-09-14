import QtQuick
import qs.Commons
import qs.Ui

// Popout under the bar glyph: URL entry, transport, volume, quality.
Panel {
  id: root
  moduleName: "ron.youtube-background"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  property bool openedFromHotkey: false

  readonly property var barIdentity: hostWidget || root
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar && bar.fontFamily ? bar.fontFamily : Style.font.family

  readonly property bool ready: service !== null
  readonly property string status: ready ? service.status : "stopped"
  readonly property bool running: ready && service.running
  readonly property bool paused: ready && service.paused
  readonly property bool muted: ready && service.muted
  readonly property real volume: ready ? service.volume : 0
  readonly property real position: ready ? service.position : 0
  readonly property real duration: ready ? service.duration : 0
  readonly property bool seekable: ready && running && service.seekable && duration > 0
  readonly property string title: ready ? service.title : ""
  readonly property string savedUrl: ready ? service.url : ""
  readonly property string lastError: ready ? service.lastError : ""
  readonly property string stream: ready ? service.stream : ""
  readonly property string cookiesFile: ready ? service.cookies : ""

  readonly property string statusLabel: {
    if (!ready) return "Service not loaded"
    switch (status) {
      case "playing": return stream !== "" ? "Playing · " + stream : "Playing"
      case "paused": return stream !== "" ? "Paused · " + stream : "Paused"
      case "starting": return ready && service.probing ? "Resolving with yt-dlp…" : "Loading stream…"
      case "error": return "Error"
      default: return "Stopped"
    }
  }

  readonly property string statusIcon: {
    switch (status) {
      case "playing": return "󰐊"
      case "paused": return "󰏤"
      case "starting": return "󰦖"
      case "error": return "󰀦"
      default: return "󰓛"
    }
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    syncField()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    syncField()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
  }

  function syncField() {
    if (!urlField.activeFocus) urlField.text = root.savedUrl
    if (!cookiesField.activeFocus) cookiesField.text = root.cookiesFile
  }

  onSavedUrlChanged: syncField()
  onCookiesFileChanged: syncField()

  function submitCookies() {
    if (!ready) return
    var value = cookiesField.text.trim()
    if (value === root.cookiesFile) return
    service.setCookies(value)
  }

  function submitUrl() {
    if (!ready) return
    var value = urlField.text.trim()
    if (value === "") return
    service.start(value)
    keyCatcher.forceActiveFocus()
  }

  function formatTime(secs) {
    var t = Math.max(0, Math.round(Number(secs) || 0))
    var h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), sec = t % 60
    var mm = h > 0 && m < 10 ? "0" + m : String(m)
    var ss = sec < 10 ? "0" + sec : String(sec)
    return (h > 0 ? h + ":" : "") + mm + ":" + ss
  }

  function qualityLabel(q) {
    return q === "best" ? "Best available" : q + "p"
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: urlField.activeFocus || cookiesField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // Space and Return never reach onTextKey: the catcher consumes them
      // as activateRequested.
      onActivateRequested: if (root.ready) root.service.togglePause()
      // Left/Right (h/l) skip 5 s, Up/Down (k/j) skip 60 s, as in mpv.
      onMoveRequested: function(dx, dy) {
        if (!root.seekable) return
        if (dx !== 0) root.service.seek(dx * 5, "relative")
        else if (dy !== 0) root.service.seek(-dy * 60, "relative")
      }
      onTextKey: function(t) {
        if (!root.ready) return
        if (t === "p") root.service.togglePause()
        else if (t === "m") root.service.setMuted(!root.muted)
        else if (t === "s") root.service.stop()
        else if (t === "u" || t === "/") { urlField.forceActiveFocus(); urlField.selectAll() }
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // ---- Now playing
        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.statusIcon
            color: root.status === "error" ? (root.bar ? root.bar.urgent : root.fg) : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
            opacity: root.status === "stopped" ? 0.5 : 1.0

            RotationAnimation on rotation {
              running: root.status === "starting"
              from: 0; to: 360
              duration: 1200
              loops: Animation.Infinite
              // Stopping mid-spin leaves the glyph at a random angle.
              onRunningChanged: if (!running) heroIcon.rotation = 0
            }
          }

          Column {
            width: parent.width - heroIcon.width - parent.spacing
            spacing: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.title !== "" ? root.title : "YouTube Background"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.lastError !== "" ? root.lastError : root.statusLabel
              color: root.lastError !== "" && root.bar ? root.bar.urgent : Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              maximumLineCount: 3
              wrapMode: Text.WordWrap
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---- URL
        PanelSectionHeader {
          text: "VIDEO"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: urlField
            width: parent.width - playButton.width - parent.spacing
            placeholderText: "YouTube URL or video id"
            foreground: root.fg
            font.family: root.fontFamily
            enabled: root.ready
            anchors.verticalCenter: parent.verticalCenter

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                urlField.text = root.savedUrl
                keyCatcher.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.submitUrl()
                event.accepted = true
              }
            }
          }

          PanelActionButton {
            id: playButton
            iconText: "󰐊"
            tooltipText: "Play this URL"
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            size: urlField.implicitHeight
            enabled: root.ready && urlField.text.trim() !== ""
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.submitUrl()
          }
        }

        // ---- Transport
        Row {
          width: parent.width
          spacing: Style.space(6)

          Button {
            width: (parent.width - parent.spacing * 2) / 3
            iconText: root.running && !root.paused ? "󰏤" : "󰐊"
            text: root.running ? (root.paused ? "Resume" : "Pause") : "Start"
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            enabled: root.ready && (root.running || root.savedUrl !== "")
            onClicked: {
              if (root.running) root.service.togglePause()
              else root.service.start()
            }
          }

          Button {
            width: (parent.width - parent.spacing * 2) / 3
            iconText: "󰓛"
            text: "Stop"
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            enabled: root.ready && root.running
            onClicked: root.service.stop()
          }

          Button {
            width: (parent.width - parent.spacing * 2) / 3
            iconText: root.muted ? "󰝟" : "󰕾"
            text: root.muted ? "Unmute" : "Mute"
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            selected: !root.muted
            enabled: root.ready
            onClicked: root.service.setMuted(!root.muted)
          }
        }

        // ---- Position (hidden for live streams and while nothing plays)
        Item {
          width: parent.width
          visible: root.seekable
          implicitHeight: Math.max(positionHeader.implicitHeight, positionTime.implicitHeight)

          PanelSectionHeader {
            id: positionHeader
            text: "POSITION"
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: positionTime
            textFormat: Text.PlainText
            text: root.formatTime(positionSlider.dragging ? positionSlider.liveValue : root.position)
              + " / " + root.formatTime(root.duration)
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        CursorSurface {
          width: parent.width
          visible: root.seekable
          height: positionSlider.implicitHeight + Style.spacing.controlGap
          foreground: root.fg
          outline: true

          PanelSlider {
            id: positionSlider
            bar: root.bar
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            minimum: 0
            maximum: Math.max(1, root.duration)
            step: 1
            integer: true
            value: root.position
            enabled: root.seekable
            onReleased: function(v) { root.service.seek(v, "absolute") }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---- Volume
        Item {
          width: parent.width
          implicitHeight: Math.max(volumeHeader.implicitHeight, volumePercent.implicitHeight)

          PanelSectionHeader {
            id: volumeHeader
            text: "VOLUME"
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: volumePercent
            textFormat: Text.PlainText
            text: Math.round(volumeSlider.dragging ? volumeSlider.liveValue : root.volume) + "%"
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            opacity: root.muted ? 0.5 : 1.0
          }
        }

        CursorSurface {
          width: parent.width
          height: volumeSlider.implicitHeight + Style.spacing.controlGap
          foreground: root.fg
          outline: true

          PanelSlider {
            id: volumeSlider
            bar: root.bar
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            value: root.volume
            opacity: root.muted ? 0.5 : 1.0
            enabled: root.ready
            onReleased: function(v) { root.service.setVolume(v) }
            onRightClicked: root.service.setMuted(!root.muted)
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---- Options
        PanelSectionHeader {
          text: "OPTIONS"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Dropdown {
          width: parent.width
          label: "Max quality"
          fontFamily: root.fontFamily
          options: root.ready
            ? root.service.qualityOptions.map(function(q) { return { value: q, label: root.qualityLabel(q) } })
            : []
          value: root.ready ? root.service.quality : "1080"
          enabled: root.ready
          onChanged: function(v) { root.service.setQuality(v) }
        }

        Dropdown {
          width: parent.width
          label: "Preferred codec"
          fontFamily: root.fontFamily
          options: [
            { value: "h264", label: "H.264 (lightest, hardware decode everywhere)" },
            { value: "vp9", label: "VP9" },
            { value: "any", label: "Whatever yt-dlp ranks best" }
          ]
          value: root.ready ? root.service.codec : "h264"
          enabled: root.ready
          onChanged: function(v) { root.service.setCodec(v) }
        }

        Toggle {
          width: parent.width
          label: "Pause when hidden"
          description: "Let mpvpaper pause while windows fully cover the desktop"
          checked: root.ready && root.service.autoPause
          foreground: root.fg
          fontFamily: root.fontFamily
          enabled: root.ready
          onClicked: root.service.setAutoPause(!root.service.autoPause)
        }

        Toggle {
          width: parent.width
          label: "Fill the screen"
          description: "Crop instead of letterboxing when aspect ratios differ"
          checked: root.ready && root.service.fill
          foreground: root.fg
          fontFamily: root.fontFamily
          enabled: root.ready
          onClicked: root.service.setFill(!root.service.fill)
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Cookies (optional)"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: cookiesField
            width: parent.width
            placeholderText: "brave+gnomekeyring:Default  or  ~/cookies.txt"
            foreground: root.fg
            font.family: root.fontFamily
            enabled: root.ready

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                cookiesField.text = root.cookiesFile
                keyCatcher.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.submitCookies()
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }
            onActiveFocusChanged: if (!activeFocus) root.submitCookies()
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "For videos gated by \"Sign in to confirm you're not a bot\": a browser spec (see README) or a Netscape cookies.txt path."
            color: Qt.darker(root.fg, 1.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "space pause · ←/→ 5 s · ↑/↓ 60 s · m mute · s stop · u url · esc close"
          color: Qt.darker(root.fg, 1.7)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
