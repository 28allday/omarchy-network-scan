import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the network-scan panel. Clicking runs the exact same IPC route
// the SUPER+ALT+N keybinding uses (omarchy-shell shell toggle …), mirroring how
// the first-party omarchy.menu bar widget summons its panel. Static icon only —
// nothing is scanned, and no process runs, while the panel is closed.
BarWidget {
  id: root
  moduleName: "nosignal.network-scan"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰛳"
    tooltipText: "My network"
    foreground: Color.accent
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle nosignal.network-scan")
    }
  }
}
