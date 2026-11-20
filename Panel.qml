import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// CraftBot in the bar: the mascot shows what the agent is doing (asleep when
// CraftBot is offline, antenna signalling while it works, eyes darting while
// it thinks, red antenna when it is waiting on you, a small hop when a run
// finishes). Left click opens the panel, right click opens CraftBot, middle
// click refreshes.
Panel {
  id: widget
  moduleName: "craftbot.status"
  ipcTarget: "craftbot.status"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  property double now: Date.now()
  property real hop: 0

  readonly property string statusText: {
    switch (craftbot.key) {
    case "waiting": return strings.t("status.waiting")
    case "running": return strings.t("status.running").arg(craftbot.running.join(", "))
    case "thinking": return strings.t("status.thinking")
    case "working": return strings.t("status.working")
    case "idle": return strings.t("status.idle")
    default: return craftbot.checked ? strings.t("status.offline") : strings.t("status.connecting")
    }
  }

  readonly property string noticeText: {
    if (craftbot.lastError !== "") return craftbot.lastError
    if (craftbot.pendingVerb === "start") return strings.t("service.starting")
    if (craftbot.pendingVerb === "stop") return strings.t("service.stopping")
    if (craftbot.pendingVerb === "restart") return strings.t("service.restarting")
    if (craftbot.serviceState === "failed") return strings.t("service.failed").arg(craftbot.unit)
    if (craftbot.notInstalled) return strings.t("install.help")
    if (craftbot.checked && !craftbot.online) return strings.t("offline.help")
    return ""
  }

  // Light themes get the dark twin of white provider marks.
  readonly property bool lightSurface: {
    var c = Commons.Color.background
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b >= 0.5
  }

  function ago(ms) { return Model.ago(ms, widget.now, strings.t) }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    now = Date.now()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  Service {
    id: craftbot
    settings: widget.settings
    panelOpen: widget.opened
  }

  Connections {
    target: craftbot
    function onRunFinished() { hopAnimation.restart() }
  }

  // Confirms a finished run: up and settle, under 300ms, ease-out only.
  SequentialAnimation {
    id: hopAnimation
    NumberAnimation { target: widget; property: "hop"; to: 1; duration: Style.duration(120); easing.type: Easing.OutCubic }
    NumberAnimation { target: widget; property: "hop"; to: 0; duration: Style.duration(160); easing.type: Easing.OutCubic }
  }

  Timer {
    interval: 30000
    running: widget.opened
    repeat: true
    onTriggered: widget.now = Date.now()
  }

  ShellIpc {
    target: widget.ipcTarget
    function open(): void { widget.open() }
    function close(): void { widget.close() }
    function show(): void { widget.open() }
    function hide(): void { widget.close() }
    function toggle(): void { widget.toggle() }
    function refresh(): string { craftbot.refresh(); return "ok" }
    function status(): string { return craftbot.key }
    function launch(): void { craftbot.openUi() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: widget.bar
    tooltipText: widget.opened ? "" : strings.t("tooltip").arg(widget.statusText)
    iconComponent: Component {
      Item {
        MascotGlyph {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize
          bodyColor: widget.barForeground
          eyeColor: widget.accent
          antennaColor: craftbot.key === "waiting" ? widget.urgent : widget.accent
          eyesClosed: !craftbot.online
          pulsing: craftbot.busy || craftbot.key === "waiting"
          glancing: craftbot.key === "thinking"
          hop: widget.hop
          opacity: craftbot.online ? 1 : 0.5
        }
      }
    }
    onPressed: function(code) {
      // Offline there is no UI to open, so right click shows the panel instead.
      if (code === Qt.RightButton && craftbot.online) craftbot.openUi()
      else if (code === Qt.MiddleButton) craftbot.refresh()
      else widget.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: widget
    bar: widget.bar
    open: widget.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(660))

    content: PanelKeyCatcher {
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onActivateRequested: craftbot.openUi()
      onCloseRequested: widget.close()
      onTabRequested: function(direction) { widget.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") craftbot.refresh()
        else if (t === "o" || t === "O") craftbot.openUi()
      }

      Flickable {
        id: flick
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
          width: flick.width
          spacing: Style.space(12)

          Hero {
            id: hero
            width: parent.width
            title: craftbot.online ? craftbot.agentName : strings.t("title")
            version: craftbot.online && craftbot.version !== "" ? strings.t("meta.version").arg(craftbot.version) : ""
            meta: widget.statusText
            foreground: widget.foreground
            fontFamily: widget.fontFamily
            iconComponent: Component {
              MascotGlyph {
                iconSize: Style.font.display * 1.15
                bodyColor: hero.foreground
                eyeColor: widget.accent
                antennaColor: craftbot.key === "waiting" ? widget.urgent : widget.accent
                eyesClosed: !craftbot.online
                pulsing: craftbot.busy || craftbot.key === "waiting"
                glancing: craftbot.key === "thinking"
                hop: widget.hop
                opacity: craftbot.online ? 1 : 0.55
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: serviceSwitch
                visible: craftbot.serviceKnown
                checked: craftbot.pendingVerb === "" ? craftbot.serviceUp : craftbot.pendingVerb !== "stop"
                busy: craftbot.controlBusy
                foreground: hero.foreground
                onToggled: craftbot.control(craftbot.serviceUp ? "stop" : "start")

                PanelToolTip {
                  visible: serviceSwitch.containsMouse
                  text: craftbot.serviceUp ? strings.t("toggle.on") : strings.t("toggle.off")
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          PlainText {
            visible: widget.noticeText !== ""
            width: parent.width
            text: widget.noticeText
            color: craftbot.lastError !== "" || craftbot.serviceState === "failed" ? widget.urgent : widget.dim
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            elide: Text.ElideNone
          }

          Row {
            spacing: Style.space(8)

            Button {
              visible: craftbot.online
              iconText: "󰏌"
              text: strings.t("action.open")
              foreground: widget.foreground
              fontFamily: widget.fontFamily
              onClicked: craftbot.openUi()
            }
            Button {
              visible: craftbot.notInstalled
              iconText: "󰏌"
              text: strings.t("action.getCraftbot")
              foreground: widget.foreground
              fontFamily: widget.fontFamily
              onClicked: craftbot.openInstallGuide()
            }
            Button {
              visible: craftbot.canStart
              enabled: !craftbot.controlBusy
              iconText: "󰐊"
              text: strings.t("action.start")
              foreground: widget.foreground
              fontFamily: widget.fontFamily
              onClicked: craftbot.control("start")
            }
            Button {
              visible: craftbot.serviceKnown && (craftbot.serviceUp || craftbot.serviceState === "failed")
              enabled: !craftbot.controlBusy
              iconText: "󰑓"
              text: strings.t("action.restart")
              foreground: widget.foreground
              fontFamily: widget.fontFamily
              onClicked: craftbot.control("restart")
            }
          }

          PanelSeparator { visible: craftbot.online; foreground: widget.foreground }

          // ── Model and provider ──
          RowLayout {
            visible: craftbot.online
            width: parent.width
            spacing: Style.space(10)

            Image {
              visible: status === Image.Ready
              Layout.preferredWidth: Style.space(22)
              Layout.preferredHeight: Style.space(22)
              Layout.alignment: Qt.AlignVCenter
              source: {
                var path = Model.providerIcon(craftbot.provider, widget.lightSurface)
                return path === "" ? "" : Qt.resolvedUrl(path)
              }
              sourceSize.width: Style.space(44)
              sourceSize.height: Style.space(44)
              fillMode: Image.PreserveAspectFit
              smooth: true
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0
              PlainText {
                Layout.fillWidth: true
                text: craftbot.model || strings.t("model.unknown")
                font.pixelSize: Style.font.body
                font.bold: true
              }
              PlainText {
                Layout.fillWidth: true
                text: Model.providerLabel(craftbot.provider) || strings.t("model.unknown")
                color: widget.dim
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator { visible: craftbot.online; foreground: widget.foreground }

          Column {
            visible: craftbot.online
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: strings.t("section.sessions")
              foreground: widget.foreground
              fontFamily: widget.fontFamily
            }

            PlainText {
              visible: craftbot.sessions.length === 0
              width: parent.width
              text: strings.t("sessions.none")
              color: widget.dim
            }

            Repeater {
              model: craftbot.sessions
              SessionRow {
                required property var modelData
                width: parent.width
                session: modelData
              }
            }
          }
        }
      }
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: widget.foreground
    font.family: widget.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component SessionRow: CursorSurface {
    id: row
    property var session: null
    readonly property bool busy: session ? session.busy === true : false
    readonly property bool unread: session ? session.unread === true : false
    // The current step's status line from the decision reply (live socket).
    readonly property string doing: session ? String(craftbot.stepStatus[session.id] || "") : ""

    foreground: widget.foreground
    hasCursor: mouse.containsMouse
    implicitHeight: rowLayout.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: craftbot.openUi()
    }

    ColumnLayout {
      id: rowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      // Row 1: type glyph, session name, status dot.
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        PlainText {
          text: !row.session ? "" : row.session.type === "main" ? "◆" : row.session.type === "agent_app" ? "■" : "●"
          color: widget.dim
          font.pixelSize: Style.font.caption
          Layout.preferredWidth: Style.space(12)
          horizontalAlignment: Text.AlignHCenter
        }
        PlainText {
          Layout.fillWidth: true
          text: row.session ? row.session.title : ""
        }
        StatusDot {
          visible: row.busy || row.unread
          busy: row.busy
          Layout.alignment: Qt.AlignVCenter
        }
      }

      // Row 2: what the session is doing, smaller, under the name.
      Ticker {
        visible: row.doing !== ""
        Layout.fillWidth: true
        Layout.leftMargin: Style.space(12) + Style.space(8)
        Layout.rightMargin: Style.space(7) + Style.space(8)
        text: row.doing
        running: widget.opened
      }
    }
  }

  // One line of small text that scrolls when it doesn't fit: it reads from
  // the start, pauses, glides to the end at a steady pace, pauses, and starts
  // over. Like the media widget's title, it never moves with reduced motion.
  component Ticker: Item {
    id: ticker
    property string text: ""
    property bool running: true
    readonly property real overflow: Math.max(0, line.implicitWidth - width)

    implicitHeight: line.implicitHeight
    clip: true

    PlainText {
      id: line
      text: ticker.text
      color: widget.dim
      font.pixelSize: Style.font.caption
      elide: Text.ElideNone
      width: implicitWidth
    }

    SequentialAnimation {
      running: ticker.running && ticker.visible && ticker.overflow > 0 && !Style.reduceMotion && Style.duration(100) > 0
      loops: Animation.Infinite
      onRunningChanged: if (!running) line.x = 0
      PropertyAction { target: line; property: "x"; value: 0 }
      PauseAnimation { duration: Style.duration(1400) }
      NumberAnimation {
        target: line; property: "x"
        to: -ticker.overflow
        duration: Style.duration(Math.max(1500, ticker.overflow * 25))
        easing.type: Easing.Linear
      }
      PauseAnimation { duration: Style.duration(1400) }
    }
  }

  // CraftBot's sidebar session dot (NavBar.module.css): orange and pulsing
  // while the agent works in that session, steady green for unread messages.
  component StatusDot: Item {
    id: dot
    property bool busy: false
    property real phase: 0
    readonly property color tint: busy ? "#ff4f18" : "#22c55e"
    readonly property bool animate: busy && Style.duration(100) > 0
    readonly property real wave: animate ? (1 - Math.cos(phase * 2 * Math.PI)) / 2 : 0

    implicitWidth: Style.space(7)
    implicitHeight: implicitWidth

    NumberAnimation on phase {
      running: dot.animate
      from: 0; to: 1
      duration: Style.duration(1400)
      loops: Animation.Infinite
      onRunningChanged: if (!running) dot.phase = 0
    }

    // The ring that spreads 3px out and fades, as the CSS box-shadow does.
    Rectangle {
      anchors.centerIn: parent
      width: parent.width + 2 * Style.space(3) * dot.wave
      height: width
      radius: width / 2
      color: Util.alpha(dot.tint, 0.55 * (1 - dot.wave))
      visible: dot.animate
    }
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: dot.tint
      opacity: 1 - 0.45 * dot.wave
    }
  }

  // PanelHero's layout (Ui/PanelHero.qml), with the version set small and
  // dim right after the title instead of in a pill.
  component Hero: Item {
    id: heroRoot
    property Component iconComponent: null
    property string title: ""
    property string version: ""
    property string meta: ""
    property color foreground: Commons.Color.foreground
    property string fontFamily: Style.font.family
    property Component trailingControl: null
    readonly property color dim: Qt.darker(foreground, 1.4)
    readonly property real trailingInset: trailingLoader.item && trailingLoader.item.visible ? trailingLoader.width + Style.space(12) : 0

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(iconLoader.implicitHeight, heroLabels.implicitHeight, trailingLoader.implicitHeight)

    Loader {
      id: iconLoader
      sourceComponent: heroRoot.iconComponent
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Column {
      id: heroLabels
      anchors.left: iconLoader.right
      anchors.leftMargin: Style.space(14)
      anchors.right: parent.right
      anchors.rightMargin: heroRoot.trailingInset
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          id: heroTitle
          textFormat: Text.PlainText
          text: heroRoot.title
          width: Math.min(implicitWidth, Math.max(0, parent.width - (heroVersion.visible ? heroVersion.implicitWidth + parent.spacing : 0)))
          color: heroRoot.foreground
          font.family: heroRoot.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          id: heroVersion
          visible: heroRoot.version !== ""
          anchors.baseline: heroTitle.baseline
          textFormat: Text.PlainText
          text: heroRoot.version
          color: heroRoot.dim
          opacity: 0.8
          font.family: heroRoot.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: heroRoot.meta.toUpperCase()
        visible: text !== ""
        color: heroRoot.dim
        font.family: heroRoot.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
        elide: Text.ElideRight
      }
    }

    Loader {
      id: trailingLoader
      sourceComponent: heroRoot.trailingControl
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
