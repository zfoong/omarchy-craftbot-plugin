import QtQuick
import qs.Commons

// The CraftBot mascot, redrawn from rectangles so it stays crisp at bar size:
// a rounded body, two pill eyes, and the antenna (stem + dot) on the left.
// Proportions come from the app's mascot art, measured against body width.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color bodyColor: "white"
  property color eyeColor: "#ff4f18"
  property color antennaColor: eyeColor

  property bool eyesClosed: false   // offline: sleeping
  property bool pulsing: false      // antenna signal while CraftBot works
  property bool glancing: false     // eyes look around while it thinks
  property real hop: 0              // 0..1, lifted by the owner

  readonly property real aspectRatio: 1 / 1.24
  readonly property real u: height / 1.24        // body width
  readonly property real minLine: Math.max(1, iconSize / 9)
  readonly property bool animate: Style.duration(100) > 0

  width: iconSize * aspectRatio
  height: iconSize
  implicitWidth: width
  implicitHeight: height

  property real eyeShift: 0
  property real antennaLevel: 1

  Item {
    id: figure
    width: root.width
    height: root.height
    y: -root.hop * root.height * 0.14

    // Antenna dot
    Rectangle {
      width: Math.max(root.minLine * 1.2, root.u * 0.142)
      height: width
      radius: width / 2
      x: root.u * 0.268 - width / 2
      y: 0
      color: root.antennaColor
      opacity: root.antennaLevel
      antialiasing: true
    }
    // Antenna stem
    Rectangle {
      width: Math.max(root.minLine, root.u * 0.143)
      height: root.u * 0.26
      x: root.u * 0.268 - width / 2
      y: root.u * 0.19
      radius: Math.min(width / 2, root.u * 0.03)
      color: root.antennaColor
      antialiasing: true
    }
    // Body
    Rectangle {
      id: body
      x: 0
      y: root.u * 0.43
      width: root.u
      height: root.u * 0.81
      radius: Math.max(0.5, root.u * 0.07)
      color: root.bodyColor
      antialiasing: true

      Repeater {
        model: [0.404, 0.707]
        Rectangle {
          required property var modelData
          readonly property real openHeight: root.u * 0.335
          width: Math.max(root.minLine, root.u * 0.14)
          height: root.eyesClosed ? Math.max(root.minLine * 0.8, root.u * 0.06) : openHeight
          radius: width / 2
          x: root.u * modelData + root.eyeShift * root.u * 0.06
          y: root.u * 0.179 + (openHeight - height) * 0.6
          color: root.eyeColor
          antialiasing: true
          Behavior on height { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
        }
      }
    }
  }

  // Working: the antenna sends a slow signal (constant motion, like a spinner).
  SequentialAnimation on antennaLevel {
    running: root.pulsing && root.animate
    loops: Animation.Infinite
    onRunningChanged: if (!running) root.antennaLevel = 1
    NumberAnimation { to: 0.25; duration: Style.duration(700); easing.type: Easing.Linear }
    NumberAnimation { to: 1; duration: Style.duration(700); easing.type: Easing.Linear }
  }

  // Thinking: eyes drift left and right.
  SequentialAnimation on eyeShift {
    running: root.glancing && root.animate
    loops: Animation.Infinite
    onRunningChanged: if (!running) root.eyeShift = 0
    PauseAnimation { duration: Style.duration(600) }
    NumberAnimation { to: -1; duration: Style.duration(260); easing.type: Easing.OutCubic }
    PauseAnimation { duration: Style.duration(900) }
    NumberAnimation { to: 1; duration: Style.duration(300); easing.type: Easing.OutCubic }
    PauseAnimation { duration: Style.duration(900) }
    NumberAnimation { to: 0; duration: Style.duration(260); easing.type: Easing.OutCubic }
  }
}
