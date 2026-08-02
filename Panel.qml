import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// "My Network" panel. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle nosignal.network-scan
// The host calls open(payloadJson) / close() and reads `opened`; it also
// injects `shell` right after the Loader resolves (see onShellChanged).
//
// All the discovery lives in scan.sh next to this file — keeping it a real
// script rather than a QML string keeps it shellcheck-able and runnable by
// hand when something looks wrong. It is invoked twice per open:
//
//   scan.sh fast   passive: neighbour table + mDNS + Tailscale, ~1s
//   scan.sh deep   adds a /24 ping sweep and a TCP probe of 18 ports, ~6s
//
// The fast pass exists so the panel paints a real list immediately instead of
// staring at a spinner; the deep pass then replaces it wholesale (same JSON
// shape, so one parser handles both). Nothing runs while the panel is closed.
//
// The two sections scroll INDEPENDENTLY, each showing at most maxVisibleRows
// devices. A single shared list would bury the Tailscale section below twenty
// LAN devices and make it reachable only by scrolling past all of them.
//
// Identification is a best guess, deliberately: an advertised mDNS service is
// trusted over an open port, an open port over a MAC vendor, and anything
// unrecognised stays "Unknown device" rather than being guessed at.
Item {
  id: root

  property bool opened: false

  readonly property string selfId: "nosignal.network-scan"

  // Injected by the shell host after the Loader resolves. Used to keep the
  // host's open-flag honest on close(), and to self-restore if the host's
  // panel Instantiator rebuild destroys a visibly-open instance.
  property var shell: null
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  // scan.sh sits beside this file; strip the file:// scheme for argv.
  readonly property string scriptPath: String(Qt.resolvedUrl("scan.sh")).replace(/^file:\/\//, "")

  // ------------------------------------------------------------------ state
  property var iface: null            // { ifname, cidr, self, gateway, partial }
  property var devices: []            // [{ ip, mac, vendor, name, model, services, ports, self, gw }]
  property var peers: []              // [{ name, dns, ip, os, online, exitNode }]
  property var sshHosts: []           // [{ alias, host }] from ~/.ssh/config
  property var tsSelf: null
  property string tsState: ""         // non-empty => tailscale present but not Running
  property bool haveTailscale: false

  property bool loaded: false
  property bool scanning: false
  property bool noJq: false
  property bool noNet: false

  // Per-section row lists, each a mix of {kind:"group"} captions and device or
  // peer rows. `items` is the two concatenated, and selection runs as one flat
  // cursor over it — devices first, then peers — so ↓ walks off the end of the
  // LAN list straight into the Tailscale list. Rendering stays two separate
  // lists; sectionRows() maps a section back to the rows that belong to it.
  property var lanRows: []
  property var tsRows: []
  property var items: []
  readonly property int lanCount: root.lanRows.length
  property int selectedIndex: -1
  property bool cursorActive: true

  // `e` expands every row at once instead of just the selected one. Off by
  // default: the compact list is what makes a twenty-device network scannable.
  // Survives closing the panel, so it stays on for whoever wants it that way.
  property bool showAllDetail: false

  // Shares the [menu] surface tokens so themes that style the menu style this
  // panel too — same approach as the sibling nosignal.* panels.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color selBg: Color.menu.selectedBackground
  property color selText: Color.menu.selectedText
  property color accent: Color.accent
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.xxxl
  property int sectionGap: Style.spacing.xxl
  // Title line plus the verdict line beneath it.
  readonly property int titleRowH: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int verdictH: Style.font.caption + Style.spacing.sm
  property int headerHeight: root.titleRowH + root.verdictH

  // Row geometry. Rows are a fixed two lines so keyboard scrolling can keep
  // the selection visible without probing delegate positions.
  readonly property int rowPadV: Style.spacing.lg
  readonly property int rowPadH: Style.spacing.lg
  readonly property int rowGap: Style.spacing.xs
  readonly property int titleLineH: Style.font.title + Style.spacing.xs
  readonly property int captionLineH: Style.font.caption + Style.spacing.xxs
  // A collapsed row is one line: name, role, address, tag. Everything else —
  // OS, vendor, ports, MAC — appears only on the selected row, so a list of
  // twenty devices reads as a list rather than a wall of detail.
  readonly property int rowH: root.rowPadV * 2 + root.titleLineH
  readonly property int detailRowH: root.captionLineH + Style.spacing.xs
  readonly property int detailPadV: Style.spacing.sm
  readonly property int headRowH: Style.font.caption + Style.spacing.xxl
  readonly property int groupRowH: Style.font.caption + Style.spacing.xl

  function detailBlockH(row) {
    var n = root.detailFields(row).length
    return n === 0 ? 0 : root.detailPadV + n * root.detailRowH
  }

  // Height of one row, whichever kind it is. Group captions are short; device
  // rows grow only in the `e` mode.
  function rowHeightOf(row) {
    if (!row) return 0
    if (row.kind === "group") return root.groupRowH
    return root.rowH + (root.showAllDetail ? root.detailBlockH(row) : 0)
  }

  function rowsHeight(rows, from, to) {
    var t = 0
    for (var i = from; i < to && i < rows.length; i++) {
      t += root.rowHeightOf(rows[i])
      if (i > from) t += root.rowGap
    }
    return t
  }

  function sectionRows(peerSection) { return peerSection ? root.tsRows : root.lanRows }

  // Past this many device rows, a section scrolls instead of growing. Group
  // captions are allowed on top so a group never costs you a device.
  readonly property int maxVisibleRows: 8

  function sectionViewH(rows, peerSection) {
    if (rows.length === 0) return root.rowH   // leaves room for the empty-state note
    // With every row expanded, ask for the lot and let the card's 80%-of-screen
    // ceiling do the capping — so `e` grows the panel to show as much as it can
    // rather than squeezing tall rows into a height meant for short ones.
    if (root.showAllDetail) return root.sectionContentH(rows, peerSection)
    var groups = 0
    for (var i = 0; i < rows.length; i++) if (rows[i].kind === "group") groups++
    var limit = Math.min(rows.length, root.maxVisibleRows + groups)
    return root.rowsHeight(rows, 0, limit)
  }

  // Content height computed rather than read back from the Flickable, so
  // scrolling doesn't depend on the Column having re-laid-out this frame after
  // a row expanded or collapsed.
  function sectionContentH(rows, peerSection) {
    return root.rowsHeight(rows, 0, rows.length)
  }

  // A section's full block: its header plus its (capped) list.
  readonly property real lanBlockH: root.headRowH + root.sectionViewH(root.lanRows, false)
  readonly property real tsBlockH: root.headRowH + root.sectionViewH(root.tsRows, true)

  // ------------------------------------------------------- self-registration

  // Keep the keyboard shortcut working with the bar on, off, or absent.
  //
  // `omarchy plugin enable` writes only the `bar.layout` entry for a plugin
  // that is both a panel and a bar widget: PluginRegistry.setEnabled picks the
  // bar branch of an if/else chain, so the `plugins[]` push below it is never
  // reached. The panel is then enabled only for as long as its icon sits in
  // the bar — take the icon out, or never want one, and the shell stops
  // instantiating the panel, so `omarchy-shell shell toggle` exits 0 and does
  // nothing. That is what "the keybinding doesn't work" turns out to be.
  //
  // So the first time we open, claim a `plugins[]` reference of our own. That
  // reference is enough on its own, so from then on the shortcut survives the
  // icon being removed. Idempotent, writes through a temp file, and inert once
  // a shell that writes both references itself has landed.
  //
  // It cannot repair an install that is already switched off: with no
  // reference the shell never loads this panel, so none of this runs. That
  // case needs `omarchy plugin enable <id>` once.
  //
  // Harness: sh -c <script> plugin-selfref <id> — $0 is the label, $1 the id.
  property bool selfRefEnsured: false
  readonly property string ensureSelfRefScript: [
    'id="$1"',
    'f="$HOME/.config/omarchy/shell.json"',
    '[ -f "$f" ] || exit 0',
    'jq -e --arg id "$id" \'any(.plugins[]?; (.id // empty) == $id)\' "$f" >/dev/null && exit 0',
    'tmp="$f.selfref.$$"',
    'jq --arg id "$id" \'.plugins = ((.plugins // []) + [{id: $id}])\' "$f" > "$tmp" || {',
    '  rm -f "$tmp"; exit 1;',
    '}',
    '[ -s "$tmp" ] || { rm -f "$tmp"; exit 1; }',
    'mv "$tmp" "$f"'
  ].join("\n")

  function ensureSelfReference() {
    if (root.selfRefEnsured) return
    root.selfRefEnsured = true
    Quickshell.execDetached(["sh", "-c", root.ensureSelfRefScript, "plugin-selfref", root.selfId])
  }

  function open(payloadJson) {
    root.opened = true
    root.ensureSelfReference()
    // Start at the top each time. The panel object outlives a close, so a
    // stale index would otherwise leave the cursor wherever it was last —
    // and grouping means that index no longer even refers to the same device.
    root.selectedIndex = -1
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    // Don't leave a chooser up to reappear on the next open — the panel can be
    // dismissed by a click outside the card while it's raised.
    root.closeChooser()
    // Keep the host's openPanelIds in sync so an Esc-closed panel doesn't
    // wrongly self-restore on the next delegate rebuild.
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // Fast pass first for something to look at; deep pass is chained off it.
  function refresh() {
    if (fastProc.running || deepProc.running) return
    root.scanning = true
    fastProc.running = true
  }

  // ------------------------------------------------------------ formatting

  function shortMac(mac) {
    return String(mac || "").toUpperCase()
  }

  // Vendor names in the IEEE list are legal entity names; trim the noise.
  function tidyVendor(v) {
    var s = String(v || "").trim()
    if (s === "") return ""
    s = s.replace(/[,.]?\s*(CO\.?|CORP\.?|CORPORATE|CORPORATION|COMPANY|INC\.?|LTD\.?|LIMITED|GMBH|B\.?V\.?|S\.?A\.?|PLC|LLC|TECHNOLOGIES|TECHNOLOGY|ELECTRONICS|SEMICONDUCTOR)\b\.?/gi, "")
    s = s.replace(/[\s,]+$/, "").replace(/\s{2,}/g, " ").trim()
    return s === "" ? String(v).trim() : s
  }

  // Best label for the row: a real advertised name beats an inferred role,
  // which beats the maker's name, which beats the bare address.
  function displayName(d) {
    if (d.name && String(d.name).trim() !== "") return String(d.name)
    var c = root.classify(d)
    if (c.role !== "Unknown device") return c.role
    // Nothing identified it: naming the maker still beats repeating the
    // address, which is already shown on the right of the same line.
    var vend = root.tidyVendor(d.vendor)
    if (vend !== "" && vend.charAt(0) !== "(") return vend + " device"
    return String(d.ip)
  }

  // Identification. Ordered strongest-signal-first: an mDNS service the device
  // advertises about itself, then a distinctive open port, then the MAC
  // vendor, then generic ports. Anything unrecognised stays unknown rather
  // than being invented.
  function classify(d) {
    if (!d) return { glyph: "󰋗", role: "Unknown device" }
    if (d.gw) return { glyph: "󰑩", role: "Router / gateway" }
    if (d.self) return { glyph: "󰟀", role: "This machine" }

    var svc = (d.services || []).join(" ").toLowerCase()
    var model = String(d.model || "").toLowerCase()
    var vend = String(d.vendor || "").toLowerCase()
    var ports = d.ports || []
    function p(n) { return ports.indexOf(n) >= 0 }
    function s(n) { return svc.indexOf(n) >= 0 }
    function v(n) { return vend.indexOf(n) >= 0 }

    // --- advertised services
    if (s("_ipp") || s("_printer") || s("_pdl-datastream") || s("_scanner"))
      return { glyph: "󰐪", role: "Printer" }
    if (s("_googlecast"))
      return { glyph: "󰄉", role: "Chromecast / Google TV" }
    if (s("_sonos") || s("_spotify-connect"))
      return { glyph: "󰓃", role: "Speaker" }
    if (s("_hap") || s("_matter") || s("_hue") || s("_homekit"))
      return { glyph: "󰌵", role: "Smart-home device" }
    if (s("_androidtvremote") || s("_roku") || s("_viziocast"))
      return { glyph: "󰠹", role: "TV / media box" }
    if (s("_airplay") || s("_raop") || s("_companion-link")) {
      if (model.indexOf("appletv") === 0) return { glyph: "󰠹", role: "Apple TV" }
      if (model.indexOf("audioaccessory") === 0) return { glyph: "󰓃", role: "HomePod" }
      if (model.indexOf("iphone") === 0) return { glyph: "󰄜", role: "iPhone" }
      if (model.indexOf("ipad") === 0) return { glyph: "󰄜", role: "iPad" }
      if (model.indexOf("macbook") === 0) return { glyph: "󰌢", role: "MacBook" }
      if (model.indexOf("mac") === 0 || model.indexOf("imac") === 0) return { glyph: "󰀵", role: "Mac" }
      return { glyph: "󰀵", role: "AirPlay device" }
    }

    // --- distinctive open ports
    if (p(9100) || p(631)) return { glyph: "󰐪", role: "Printer" }
    if (p(32400)) return { glyph: "󰠹", role: "Plex server" }
    if (p(8096)) return { glyph: "󰠹", role: "Jellyfin server" }
    if (p(8123)) return { glyph: "󰌵", role: "Home Assistant" }
    if (p(8006)) return { glyph: "󰒋", role: "Proxmox host" }
    if (p(1883)) return { glyph: "󰌵", role: "MQTT broker" }
    if (p(548) || (p(5000) && (v("synology") || v("qnap") || v("western digital"))))
      return { glyph: "󰋊", role: "NAS" }
    if (p(3389) || p(5357)) return { glyph: "󰟀", role: "Windows PC" }
    if (p(445) || p(139)) return { glyph: "󰋊", role: "File share" }

    // --- MAC vendor. Weaker than a distinctive port but stronger than the
    // generic ones below: every access point and switch on earth answers on
    // 22 and 80, so "made by a networking vendor" beats calling it a server.
    if (v("raspberry")) return { glyph: "󰒋", role: "Raspberry Pi" }
    if (v("espressif")) return { glyph: "󰌵", role: "ESP / IoT device" }
    if (v("apple")) return { glyph: "󰀵", role: "Apple device" }
    if (v("sonos")) return { glyph: "󰓃", role: "Sonos speaker" }
    if (v("ubiquiti") || v("tp-link") || v("netgear") || v("mercusys")
        || v("zyxel") || v("d-link") || v("aruba") || v("cisco"))
      return { glyph: "󰑩", role: "Network gear" }
    if (v("hikvision") || v("dahua") || v("axis communications"))
      return { glyph: "󰄀", role: "IP camera" }
    if (v("amazon")) return { glyph: "󰓃", role: "Amazon device" }
    if (v("google")) return { glyph: "󰄉", role: "Google device" }
    if (v("samsung") || v("lg electronics") || v("sony")) return { glyph: "󰠹", role: "TV / consumer device" }

    // --- generic ports: these say a service is listening, not what the box is
    // for.
    if (p(22) && (p(80) || p(443))) return { glyph: "󰒋", role: "Server" }
    if (p(22)) return { glyph: "󰒋", role: "SSH host" }
    if (p(80) || p(443) || p(8080)) return { glyph: "󰖟", role: "Web device" }

    // --- naming convention, last of all. Weak, but a sleeping laptop offers
    // nothing else: no mDNS, no open ports, no vendor worth much. Leaving a
    // host called "…-MacBook-Pro" in "Other" is worse than reading its name.
    var nm = String(d.name || "").toLowerCase()
    if (/macbook/.test(nm)) return { glyph: "󰌢", role: "MacBook" }
    if (/imac|mac-?mini|mac-?pro|mac-?studio|(^|[^a-z])mac([^a-z]|$)/.test(nm))
      return { glyph: "󰀵", role: "Mac" }
    if (/iphone/.test(nm)) return { glyph: "󰄜", role: "iPhone" }
    if (/ipad/.test(nm)) return { glyph: "󰄜", role: "iPad" }
    if (/^(desktop|laptop|win)-/.test(nm)) return { glyph: "󰟀", role: "Windows PC" }
    if (/thinkpad|latitude|elitebook|probook|xps|surface/.test(nm))
      return { glyph: "󰌢", role: "Laptop" }

    // --- PC hardware vendors, weakest of all. A NIC chipset or laptop OEM
    // says "computer" far more often than not, and it is frequently the ONLY
    // thing a Windows machine gives you: its default firewall drops ICMP and
    // answers no ports, and its name often fails to resolve too. Deliberately
    // "Computer" rather than a guess at which kind.
    if (root.pcVendors.test(vend)) return { glyph: "󰟀", role: "Computer" }

    return { glyph: "󰋗", role: "Unknown device" }
  }

  // Web servers that say nothing about the host OS. Embedded firmware puts its
  // own name here ("httpd/2.7 (Netgear; D86)"), which is worth reporting; a
  // Linux box fronted by nginx is not.
  readonly property var genericHttpd: /^(nginx|apache|caddy|lighttpd|gunicorn|express|werkzeug|kestrel|jetty|tornado|uvicorn|cherrypy|openresty)/i

  // Best guess at the host OS, with the evidence that produced it. Ranked by
  // how much the host actually told us: a model string or a service banner is
  // the host identifying itself, a TTL is us inferring from a packet header,
  // and a hostname convention is barely evidence at all. Returns null when
  // there is nothing honest to say.
  function osGuess(d) {
    if (!d) return null

    // 1. mDNS model — Apple devices state their hardware, which fixes the OS.
    var model = String(d.model || "").toLowerCase()
    if (model !== "") {
      if (/^(iphone|ipad|ipod)/.test(model)) return { label: "iOS / iPadOS", basis: "mdns" }
      if (/^appletv/.test(model)) return { label: "tvOS", basis: "mdns" }
      if (/^audioaccessory/.test(model)) return { label: "HomePod", basis: "mdns" }
      if (/^watch/.test(model)) return { label: "watchOS", basis: "mdns" }
      // Deliberately NOT matching airport/timecapsule: Samba and NAS firmware
      // advertise "TimeCapsule<n>,<n>" so macOS will offer them as a Time
      // Machine target. That string describes an emulated service, not the
      // host — a Linux NAS claiming it is not an Apple device.
      if (/^(mac|imac|macbook|macmini|macpro|macstudio)/.test(model)) return { label: "macOS", basis: "mdns" }
    }

    // 2. SSH banner — often names the distro outright.
    var ssh = String(d.ssh || "")
    if (ssh.indexOf("SSH-") === 0) {
      if (/dropbear/i.test(ssh)) return { label: "Embedded Linux (dropbear)", basis: "ssh" }
      if (/ubuntu/i.test(ssh)) return { label: "Ubuntu", basis: "ssh" }
      if (/raspbian/i.test(ssh)) return { label: "Raspberry Pi OS", basis: "ssh" }
      if (/debian/i.test(ssh)) return { label: "Debian", basis: "ssh" }
      if (/freebsd/i.test(ssh)) return { label: "FreeBSD", basis: "ssh" }
      if (/openbsd/i.test(ssh)) return { label: "OpenBSD", basis: "ssh" }
      if (/windows/i.test(ssh)) return { label: "Windows", basis: "ssh" }
      var ver = ssh.match(/OpenSSH[_-]([0-9][0-9.p]*)/i)
      // The version alone doesn't name a distro, so the label doesn't pretend
      // to — it reports the family and shows the version as the evidence.
      if (ver) return { label: "Linux / Unix, OpenSSH " + ver[1], basis: "ssh" }
      return { label: "Linux / Unix", basis: "ssh" }
    }

    // 3. HTTP Server header — decisive for IIS, otherwise only useful when
    // it's firmware rather than a general-purpose web server.
    var http = String(d.http || "")
    if (http !== "") {
      if (/microsoft-iis/i.test(http)) return { label: "Windows", basis: "http" }
      if (!root.genericHttpd.test(http))
        return { label: http.length > 34 ? http.slice(0, 33) + "…" : http, basis: "http" }
    }

    // 4. Reply TTL, minus hops — 0 of them on our own segment.
    var ttl = Number(d.ttl)
    if (d.ttl !== null && d.ttl !== undefined && !isNaN(ttl) && ttl > 0) {
      if (ttl <= 64) return { label: "Linux / macOS / BSD", basis: "ttl " + ttl }
      if (ttl <= 128) return { label: "Windows", basis: "ttl " + ttl }
      // 255 is the default for Solaris/AIX/Cisco IOS and a great many embedded
      // stacks — printers included — so it means "embedded", not "router".
      return { label: "Embedded / network device", basis: "ttl " + ttl }
    }

    // 5. Naming convention. Barely evidence — and flagged as such with a "?" —
    // but it's all a Windows box that drops ICMP and opens no ports will give
    // you, which is the default Windows Firewall configuration.
    var name = String(d.name || "")
    if (/^(desktop|laptop|win)-/i.test(name)) return { label: "Windows?", basis: "hostname" }

    return null
  }

  // The role, shown dimmed beside the name on the collapsed line. Omitted when
  // the name already is the role (an unnamed device headlines as its role).
  // Which camp a device belongs to, for the verdict line under the title.
  // Only confident attributions count: "Linux / macOS / BSD (ttl 64)" says a
  // Unix-ish stack and nothing more, so it deliberately isn't a vote.
  function osFamily(d) {
    var role = root.classify(d).role
    if (/^(Mac|MacBook|Apple device|Apple TV|HomePod|iPhone|iPad)$/.test(role)) return "mac"
    if (role === "Windows PC") return "windows"

    var os = root.osGuess(d)
    if (os) {
      var l = os.label.toLowerCase()
      if (/^(macos|ios|ipados|tvos|watchos)/.test(l)) return "mac"
      if (/^windows/.test(l)) return "windows"
      if (/^(ubuntu|debian|raspberry pi os|linux \/ unix|embedded linux|freebsd|openbsd)/.test(l))
        return "linux"
    }
    if (/^(Raspberry Pi|Proxmox host)$/.test(role)) return "linux"
    return ""
  }

  // The house view on your hardware choices. Deliberately broad — no counts,
  // and no claim about which camp. Windows is the hardest thing here to detect
  // (its firewall drops ICMP, answers no ports and often resolves no name), so
  // a tally would state more than the evidence supports; presence is all this
  // can honestly assert.
  function verdictLine() {
    if (!root.loaded || root.devices.length === 0) return ""
    for (var i = 0; i < root.devices.length; i++) {
      var f = root.osFamily(root.devices[i])
      if (f === "mac" || f === "windows")
        return "I see Mac/Windows boxes on this network … you have made some poor life choices"
    }
    return "100% Linux on this network — you're golden"
  }

  function roleSubtitle(d) {
    var role = root.classify(d).role
    if (role === "Unknown device") return ""
    return root.displayName(d) === role ? "" : role
  }

  // Everything the collapsed row leaves out, as label/value pairs — shown only
  // when the `e` mode is on.
  function detailFields(row) {
    // Group captions carry no device, and the hidden DeviceRow inside a caption
    // slot still evaluates its bindings — so this must tolerate being handed
    // one rather than reaching for row.d.
    if (!row || row.kind === "group") return []
    var out = []

    if (row.kind === "peer") {
      var p = row.p
      if (p.dns) out.push({ k: "Address", v: String(p.dns) })
      if (p.os) out.push({ k: "OS", v: String(p.os) })
      out.push({ k: "State", v: p.online ? "online" : "offline" })
      if (p.exitNode) out.push({ k: "Role", v: "exit node" })
      return out
    }

    var d = row.d

    // OS with the evidence behind it. Suppressed only when it came from the
    // SAME signal that produced the role — an mDNS model yielding both "Mac"
    // and "macOS" is one fact stated twice. Every other basis is independent
    // evidence and earns its line: a Pi may well be running Ubuntu.
    var os = root.osGuess(d)
    if (os) {
      var r = root.classify(d).role.toLowerCase()
      var l = os.label.toLowerCase()
      var sameSignal = os.basis === "mdns" && r !== "unknown device" && r !== ""
                       && (l.indexOf(r) === 0 || r.indexOf(l.split(" ")[0]) === 0)
      if (!sameSignal) out.push({ k: "OS", v: os.label + "   (" + os.basis + ")" })
    }

    // Say so when the name didn't come from this scan, so a remembered name
    // is never mistaken for something the device just told us.
    if (d.cached && d.name)
      out.push({ k: "Name", v: String(d.name) + "   (remembered, not seen this scan)" })

    var vend = root.tidyVendor(d.vendor)
    if (vend !== "") out.push({ k: "Vendor", v: vend })
    if (d.model && String(d.model).trim() !== "") out.push({ k: "Model", v: String(d.model) })

    out.push({ k: "Ports", v: (d.ports || []).length > 0
      ? d.ports.join(", ")
      : (d.self ? "none reachable from the LAN" : "none found") })

    if ((d.services || []).length > 0) out.push({ k: "mDNS", v: d.services.join(", ") })
    out.push({ k: "MAC", v: root.shortMac(d.mac) })
    return out
  }

  // NIC chipsets and PC/laptop OEMs. Shared by classify() — where it's the
  // last-resort "Computer" label — and by isGeneralPurpose(), so both answer
  // "is this a computer?" from the same evidence.
  readonly property var pcVendors:
    /intel|realtek|dell|hewlett|hp inc|lenovo|asustek|micro-star|gigabyte|giga-byte|asrock|foxconn|hon hai|quanta|compal|wistron|clevo|framework|system76|acer|toshiba|fujitsu|azurewave|liteon|pegatron|elitegroup|biostar|tongfang/i

  // Priority order deliberately puts the distinctive app port ahead of a bare
  // web server — :8096 tells you far more than :80 does.
  readonly property var webPortOrder: [8123, 8096, 32400, 8006, 5000, 8080, 443, 80]

  // Find the ~/.ssh/config entry that refers to this host, so SSH goes to the
  // alias — carrying its User, Port and key — rather than to a bare address,
  // which logs in as whoever is running the shell. Matches on the configured
  // HostName (usually the address) and on the alias itself, since an alias is
  // often just the device's name.
  function sshAliasFor(names, addrs) {
    function norm(s) { return String(s || "").trim().toLowerCase() }
    var wanted = []
    var i
    for (i = 0; i < names.length; i++) if (norm(names[i]) !== "") wanted.push(norm(names[i]))
    for (i = 0; i < addrs.length; i++) if (norm(addrs[i]) !== "") wanted.push(norm(addrs[i]))
    if (wanted.length === 0) return ""

    for (i = 0; i < root.sshHosts.length; i++) {
      var c = root.sshHosts[i]
      var host = norm(c.host)
      var alias = norm(c.alias)
      if (host !== "" && wanted.indexOf(host) >= 0) return String(c.alias)
      if (alias !== "" && wanted.indexOf(alias) >= 0) return String(c.alias)
    }
    return ""
  }

  // Everything you could do with this row. A device serving both a web UI and
  // SSH gets an entry for each — picking the web UI automatically would mean
  // SSH on such a host is simply unreachable from here.
  function buildActions(row) {
    var out = []
    if (!row) return out

    if (row.kind === "dev") {
      var d = row.d
      var ports = d.ports || []
      // Distinctive ports first, so the useful UI outranks a bare :80.
      for (var i = 0; i < root.webPortOrder.length; i++) {
        var p = root.webPortOrder[i]
        if (ports.indexOf(p) < 0) continue
        var https = (p === 443 || p === 8006)
        var url = (https ? "https://" : "http://") + d.ip
                  + ((p === 80 || p === 443) ? "" : ":" + p)
        out.push({ label: "Open  " + url, kind: "web", target: url })
      }
      if (ports.indexOf(22) >= 0) {
        var alias = root.sshAliasFor([d.name], [d.ip])
        var target = alias !== "" ? alias : String(d.ip)
        out.push({ label: "SSH to  " + target + (alias !== "" ? "   (ssh config)" : ""),
                   kind: "ssh", target: target })
      }
      return out
    }

    if (row.kind === "peer" && row.p.online) {
      var p = row.p
      var dns = String(p.dns || p.ip || "")

      // Tailscale's own SSH, where it's offered: authentication goes through
      // the tailnet and no key of ours is involved.
      if (p.tsSSH && dns !== "")
        out.push({ label: "Tailscale SSH to  " + dns, kind: "tsssh", target: dns })

      // A config alias is only useful here if it stays on the tailnet. The
      // alias for a peer often points at its PUBLIC address — such an alias commonly
      // resolves to a public address — and using it would route around Tailscale
      // entirely, which is the opposite of what picking a peer asks for.
      var pAlias = root.tailnetAliasFor(p)
      if (pAlias !== "")
        out.push({ label: "SSH to  " + pAlias + "   (ssh config)", kind: "ssh", target: pAlias })
      else if (dns !== "")
        out.push({ label: "SSH to  " + dns, kind: "ssh", target: dns })
    }
    return out
  }

  // Addresses that stay inside the tailnet: a MagicDNS name, or the 100.64/10
  // CGNAT range Tailscale allocates from.
  function isTailnetHost(h) {
    var s = String(h || "").trim().toLowerCase()
    if (s === "") return true          // no HostName: ssh uses the alias, which MagicDNS resolves
    if (/\.ts\.net$/.test(s)) return true
    var m = s.match(/^100\.(\d+)\./)
    return m !== null && Number(m[1]) >= 64 && Number(m[1]) <= 127
  }

  // The ssh-config alias for a peer, but only when following it keeps us on
  // the tailnet.
  function tailnetAliasFor(p) {
    function norm(s) { return String(s || "").trim().toLowerCase() }
    var dns = norm(p.dns)
    var ip = norm(p.ip)
    var nm = norm(p.name)

    for (var i = 0; i < root.sshHosts.length; i++) {
      var c = root.sshHosts[i]
      var host = norm(c.host)
      // Points straight at this peer's tailnet address or MagicDNS name.
      if (host !== "" && (host === dns || host === ip)) return String(c.alias)
      // Named after the peer, and doesn't send us off the tailnet.
      if (norm(c.alias) === nm && root.isTailnetHost(host)) return String(c.alias)
    }
    return ""
  }

  // What Enter/click will do, spelled out in the row so nothing is a surprise.
  // The ellipsis means there's more than one thing to choose from.
  function actionHint(row) {
    var a = root.buildActions(row)
    if (a.length === 0) return ""
    if (a.length > 1) return "open…"
    return a[0].kind === "ssh" ? "ssh" : "open"
  }

  // ------------------------------------------------------------ state fetch

  function parseScan(raw) {
    var lines = String(raw || "").split("\n")
    var devs = []
    var prs = []
    var sshcfg = []
    var ifc = null
    var tself = null
    var tstate = ""
    var haveTs = false
    var nojq = false
    var nonet = false

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line === "") continue
      if (line === "##NOJQ") { nojq = true; continue }
      if (line === "##NOIP" || line === "##NONET") { nonet = true; continue }
      if (line === "##END") continue

      var sp = line.indexOf(" ")
      if (sp < 0) continue
      var tag = line.slice(0, sp)
      var body = line.slice(sp + 1)

      if (tag === "##TSOFF") { haveTs = true; tstate = body; continue }
      if (tag === "##SSHCFG") {
        try { sshcfg.push(JSON.parse(body)) } catch (e2) {}
        continue
      }

      try {
        var j = JSON.parse(body)
        if (tag === "##IF") ifc = j
        else if (tag === "##DEV") devs.push(j)
        else if (tag === "##TS") { haveTs = true; prs.push(j) }
        else if (tag === "##TSSELF") { haveTs = true; tself = j }
      } catch (e) {}
    }

    root.noJq = nojq
    root.noNet = nonet
    if (ifc) root.iface = ifc
    root.devices = devs
    root.peers = prs
    root.sshHosts = sshcfg
    root.tsSelf = tself
    root.tsState = tstate
    root.haveTailscale = haveTs
    root.loaded = true
    root.rebuildItems()
  }

  Process {
    id: fastProc
    command: ["sh", root.scriptPath, "fast"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.parseScan(text)
        // Chain the deep pass — unless the panel was closed while it ran.
        if (root.opened) deepProc.running = true
        else root.scanning = false
      }
    }
  }

  Process {
    id: deepProc
    command: ["sh", root.scriptPath, "deep"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.parseScan(text)
        root.scanning = false
      }
    }
  }

  // ------------------------------------------------------------- row model

  // Devices are grouped by what they are rather than listed by address, which
  // sorts a laptop next to a light bulb. Computers lead; everything the plugin
  // couldn't identify sinks to the bottom rather than interrupting the list.
  readonly property var groupOrder: [
    "Computers", "Network", "Storage", "Media",
    "Smart home", "Printers & cameras", "Phones & tablets", "Other"
  ]

  // Vendors that build finished appliances rather than general-purpose
  // machines. A Synology box runs Linux and answers SSH, but nobody thinks of
  // it as one of their computers — it's storage.
  readonly property var applianceVendors:
    /synology|qnap|western digital|buffalo|netgear|brother|epson|canon|lexmark|hikvision|dahua|axis|sonos|amazon|google|roku|vizio/i

  // Roles that describe a *service*, which a general-purpose machine may
  // simply happen to be running.
  readonly property var serviceRoles:
    /^(Jellyfin server|Plex server|File share|NAS|Home Assistant|MQTT broker|Web device)$/

  // Is this a machine you administer, rather than an appliance? Two pieces of
  // evidence, either sufficient: an open SSH port means you can log into it,
  // and PC hardware means it was built as a computer. A box with SSH
  // switched off entirely needs the second.
  function isGeneralPurpose(d) {
    var vend = String(d.vendor || "")
    if (root.applianceVendors.test(vend)) return false
    if ((d.ports || []).indexOf(22) >= 0) return true
    return root.pcVendors.test(vend)
  }

  function groupFor(d) {
    var role = root.classify(d).role

    // A service running on a general-purpose machine is a computer running
    // that service, not an appliance. The row keeps its descriptive role
    // ("Jellyfin server", "File share"); only the grouping follows the
    // machine rather than the service it happens to host.
    if (root.serviceRoles.test(role) && root.isGeneralPurpose(d)) return "Computers"

    switch (role) {
      case "This machine": case "Mac": case "MacBook": case "Apple device":
      case "Windows PC": case "Laptop": case "Computer": case "Server":
      case "SSH host": case "Raspberry Pi": case "Proxmox host":
        return "Computers"
      case "Router / gateway": case "Network gear":
        return "Network"
      case "NAS": case "File share":
        return "Storage"
      case "Plex server": case "Jellyfin server": case "Apple TV":
      case "Chromecast / Google TV": case "TV / media box": case "Speaker":
      case "HomePod": case "Sonos speaker": case "AirPlay device":
      case "Amazon device": case "Google device": case "TV / consumer device":
        return "Media"
      case "Home Assistant": case "Smart-home device": case "ESP / IoT device":
      case "MQTT broker":
        return "Smart home"
      case "Printer": case "IP camera":
        return "Printers & cameras"
      case "iPhone": case "iPad":
        return "Phones & tablets"
      default:
        return "Other"
    }
  }

  function buildLanRows() {
    var buckets = {}
    var i
    for (i = 0; i < root.devices.length; i++) {
      var d = root.devices[i]
      var g = root.groupFor(d)
      if (!buckets[g]) buckets[g] = []
      // Carry the scanner's position so ordering within a group stays by
      // address. QML's Array.sort is not stable, so a comparator that returns
      // 0 for equal rows shuffles them — the index is the tiebreak.
      buckets[g].push({ d: d, at: i })
    }

    var rows = []
    for (var k = 0; k < root.groupOrder.length; k++) {
      var name = root.groupOrder[k]
      var list = buckets[name]
      if (!list || list.length === 0) continue
      // This machine heads its group; everything else keeps address order.
      list.sort(function(a, b) {
        var s = (b.d.self ? 1 : 0) - (a.d.self ? 1 : 0)
        return s !== 0 ? s : a.at - b.at
      })
      rows.push({ kind: "group", label: name, count: list.length })
      for (var j = 0; j < list.length; j++) rows.push({ kind: "dev", d: list[j].d })
    }
    return rows
  }

  function rebuildItems() {
    var lan = root.buildLanRows()
    var ts = []
    for (var k = 0; k < root.peers.length; k++) ts.push({ kind: "peer", p: root.peers[k] })

    root.lanRows = lan
    root.tsRows = ts
    root.items = lan.concat(ts)
    hoverGate.reset()

    if (!root.isSelectable(root.selectedIndex)) {
      root.selectedIndex = root.firstSelectable()
      root.scrollTo(root.selectedIndex)
    }
  }

  function lanNote() {
    if (!root.iface) return ""
    var n = root.devices.length
    var bits = [root.iface.ifname, root.iface.cidr,
                n + (n === 1 ? " device" : " devices")]
    if (root.iface.partial) bits.push("local /24 only")
    return bits.join("  ·  ")
  }

  function tsNote() {
    if (root.tsState !== "") return "not connected (" + root.tsState + ")"
    var online = 0
    for (var i = 0; i < root.peers.length; i++) if (root.peers[i].online) online++
    return online + " of " + root.peers.length + " peers online"
  }

  // ------------------------------------------------------------- selection

  function isSelectable(i) {
    return i >= 0 && i < root.items.length && root.items[i].kind !== "group"
  }
  function isPeerIndex(i) { return i >= root.lanCount }

  function firstSelectable() {
    for (var i = 0; i < root.items.length; i++) if (root.isSelectable(i)) return i
    return -1
  }

  function lastSelectable() {
    for (var i = root.items.length - 1; i >= 0; i--) if (root.isSelectable(i)) return i
    return -1
  }

  function beginNav() {
    hoverGate.reset()
    root.cursorActive = true
    if (!root.isSelectable(root.selectedIndex)) {
      root.selectedIndex = root.firstSelectable()
      root.scrollTo(root.selectedIndex)
      return false
    }
    return true
  }

  // One cursor over both sections: stepping off the last LAN device lands on
  // the first Tailscale peer. Group captions are stepped over, never landed on.
  function move(dir) {
    if (!root.beginNav()) return
    var i = root.selectedIndex + dir
    while (i >= 0 && i < root.items.length && root.items[i].kind === "group") i += dir
    if (i < 0 || i >= root.items.length) return
    root.selectedIndex = i
    root.scrollTo(i)
  }

  function selectEdge(fromEnd) {
    hoverGate.reset()
    root.cursorActive = true
    root.selectedIndex = fromEnd ? root.lastSelectable() : root.firstSelectable()
    root.scrollTo(root.selectedIndex)
  }

  // Offset of a row within its own list. In the default mode only the selected
  // row is expanded and every row above it is collapsed, so this is a straight
  // multiply; with showAllDetail on, the rows above have their own heights and
  // have to be summed.
  function rowOffset(i) {
    var peer = root.isPeerIndex(i)
    var rows = root.sectionRows(peer)
    var local = i - (peer ? root.lanCount : 0)
    return root.rowsHeight(rows, 0, local) + (local > 0 ? root.rowGap : 0)
  }

  // Scrolls whichever of the two lists owns the index. Heights are computed
  // rather than read off the delegates, which may not have re-laid-out yet
  // after a row collapsed.
  function scrollTo(i) {
    if (!root.isSelectable(i)) return
    var peer = root.isPeerIndex(i)
    var list = peer ? tsList : lanList
    var rows = root.sectionRows(peer)

    var contentH = root.sectionContentH(rows, peer)
    if (contentH <= list.height) { list.contentY = 0; return }

    var y = root.rowOffset(i)
    var h = root.rowHeightOf(root.items[i])
    var maxY = contentH - list.height

    // Bring the group caption above the row into view with it, so you can see
    // which group you've just stepped into.
    var localIdx = i - (peer ? root.lanCount : 0)
    if (localIdx > 0 && rows[localIdx - 1] && rows[localIdx - 1].kind === "group")
      y -= root.groupRowH + root.rowGap

    if (y < list.contentY)
      list.contentY = y
    else if (y + h > list.contentY + list.height)
      list.contentY = Math.min(maxY, y + h - list.height)
  }

  // ---------------------------------------------------------------- actions

  // Open action chooser: null, or { title, options }. Only raised when a row
  // offers more than one thing; a single action still runs straight away.
  property var chooser: null
  property int chooserIndex: 0

  function closeChooser() {
    root.chooser = null
    root.chooserIndex = 0
  }

  // A terminal launched straight into `ssh host` vanishes the instant the
  // connection is refused — which is the common case here, since the local
  // username rarely matches the device's. Holding the window open on a
  // non-zero exit turns a silent flash into a readable error.
  readonly property string sshWrapper:
    'ssh "$1" || { printf "\\n[ssh exited %s] press Enter to close " "$?"; read _; }'
  readonly property string tsSshWrapper:
    'tailscale ssh "$1" || { printf "\\n[tailscale ssh exited %s] press Enter to close " "$?"; read _; }'

  function runAction(a) {
    if (!a) return
    if (a.kind === "web") {
      Quickshell.execDetached(["omarchy-launch-browser", String(a.target)])
    } else {
      // `sh -c script name host` so the host arrives as $1 — no quoting of it
      // into the script, and the argv array means no shell on our side either.
      var wrapper = a.kind === "tsssh" ? root.tsSshWrapper : root.sshWrapper
      Quickshell.execDetached(["setsid", "uwsm-app", "--", "xdg-terminal-exec",
                               "-e", "sh", "-c", wrapper,
                               "ssh-launch", String(a.target)])
    }
    root.closeChooser()
    root.close()
  }

  // Enter/click acts on the row. One way in — do it; several — ask, rather than
  // silently picking for you. A row offering nothing does nothing, deliberately,
  // rather than opening a dead browser tab.
  function activate(i) {
    if (!root.isSelectable(i)) return
    var row = root.items[i]
    var acts = root.buildActions(row)

    if (acts.length === 0) return
    if (acts.length === 1) { root.runAction(acts[0]); return }

    root.chooser = {
      title: row.kind === "peer" ? String(row.p.name || row.p.ip)
                                 : root.displayName(row.d),
      options: acts
    }
    root.chooserIndex = 0
  }

  function moveChooser(dir) {
    if (!root.chooser) return
    var n = root.chooser.options.length
    root.chooserIndex = (root.chooserIndex + dir + n) % n
  }

  // Copy the address — the thing you actually want off this panel most often.
  function copyAddress(i) {
    if (!root.isSelectable(i)) return
    var row = root.items[i]
    var addr = row.kind === "dev" ? String(row.d.ip) : String(row.p.ip || "")
    if (addr === "") return
    Quickshell.execDetached(["sh", "-c", "command -v wl-copy >/dev/null 2>&1 && printf %s " + JSON.stringify(addr) + " | wl-copy"])
    copiedNote.show(addr)
  }

  // Only a genuine pointer move may steal the selection cursor — delegates
  // created or scrolled under a stationary mouse must not hijack keyboard
  // navigation. The card is the reference so one gate covers both lists.
  PointerMoveGate {
    id: hoverGate
    referenceItem: card
  }

  // ------------------------------------------------------------------- UI

  component SectionHeader: Item {
    id: headItem
    property string label: ""
    property string note: ""

    height: root.headRowH

    Text {
      id: headLabel
      anchors.left: parent.left
      anchors.leftMargin: root.rowPadH
      anchors.bottom: parent.bottom
      text: headItem.label.toUpperCase()
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      anchors.left: headLabel.right
      anchors.leftMargin: Style.spacing.md
      anchors.right: parent.right
      anchors.rightMargin: root.rowPadH
      anchors.baseline: headLabel.baseline
      text: headItem.note
      color: root.foreground
      opacity: 0.45
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // Divider between device groups inside the LAN section. Quieter than the
  // section header above it — it's a sub-heading, and there are several.
  component GroupCaption: Item {
    id: capItem
    property var rowData: null

    width: parent ? parent.width : 0
    height: root.groupRowH

    Text {
      id: capLabel
      anchors.left: parent.left
      anchors.leftMargin: root.rowPadH
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.spacing.xxs
      text: capItem.rowData ? String(capItem.rowData.label) : ""
      color: root.foreground
      opacity: 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      anchors.left: capLabel.right
      anchors.leftMargin: Style.spacing.sm
      anchors.baseline: capLabel.baseline
      text: capItem.rowData ? String(capItem.rowData.count) : ""
      color: root.foreground
      opacity: 0.3
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // Hairline running to the right edge, so the grouping reads at a glance
    // without shouting.
    Rectangle {
      anchors.left: capLabel.right
      anchors.right: parent.right
      anchors.leftMargin: Style.space(30)
      anchors.rightMargin: root.rowPadH
      anchors.verticalCenter: capLabel.verticalCenter
      height: 1
      color: root.foreground
      opacity: 0.12
    }
  }

  // Slim overlay indicator — the only cue that a capped section has more below.
  component ScrollHint: Rectangle {
    id: hint
    property Flickable list: null

    readonly property bool overflowing: hint.list && hint.list.contentHeight > hint.list.height

    visible: hint.overflowing
    width: Style.space(3)
    radius: width / 2
    color: root.foreground
    opacity: 0.28
    x: parent ? parent.width - width : 0
    height: hint.overflowing
            ? Math.max(Style.space(18), hint.list.height * hint.list.height / hint.list.contentHeight)
            : 0
    y: hint.overflowing
       ? (hint.list.contentY / (hint.list.contentHeight - hint.list.height))
         * (hint.list.height - height)
       : 0
  }

  component DeviceRow: Item {
    id: rowItem

    property int flatIndex: -1
    property var rowData: null
    readonly property bool isPeer: rowItem.rowData && rowItem.rowData.kind === "peer"
    readonly property var d: rowItem.rowData ? (rowItem.isPeer ? rowItem.rowData.p : rowItem.rowData.d) : null
    readonly property bool selected: root.cursorActive && rowItem.flatIndex === root.selectedIndex
    readonly property string hint: root.actionHint(rowItem.rowData)

    // Detail is shown by the `e` mode alone — selecting a row highlights it and
    // nothing more, so moving the cursor never reflows the list.
    readonly property bool expanded: root.showAllDetail
    readonly property var fields: rowItem.expanded ? root.detailFields(rowItem.rowData) : []

    width: parent ? parent.width : 0
    height: root.rowH + (rowItem.expanded ? root.detailBlockH(rowItem.rowData) : 0)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: rowItem.selected ? root.selBg : "transparent"
    }

    Item {
      id: headLine
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: root.rowPadH
      anchors.rightMargin: root.rowPadH
      anchors.topMargin: root.rowPadV
      height: root.titleLineH

      Text {
        id: glyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(22)
        text: rowItem.isPeer
              ? (rowItem.d && rowItem.d.exitNode ? "󰅧" : "󰒃")
              : (rowItem.d ? root.classify(rowItem.d).glyph : "")
        color: rowItem.isPeer && rowItem.d && !rowItem.d.online ? root.foreground : root.accent
        opacity: rowItem.isPeer && rowItem.d && !rowItem.d.online ? 0.35 : 1.0
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }

      Text {
        id: tagText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: {
          if (!rowItem.d) return ""
          if (rowItem.isPeer) return rowItem.d.online ? "online" : "offline"
          if (rowItem.d.self) return "you"
          if (rowItem.d.gw) return "gateway"
          return rowItem.hint
        }
        color: {
          if (!rowItem.d) return root.foreground
          if (rowItem.isPeer) return rowItem.d.online ? root.accent : root.foreground
          if (rowItem.d.self || rowItem.d.gw) return root.accent
          return root.foreground
        }
        opacity: {
          if (!rowItem.d) return 0.5
          if (rowItem.isPeer) return rowItem.d.online ? 0.9 : 0.35
          if (rowItem.d.self || rowItem.d.gw) return 0.9
          return 0.4
        }
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: ipText
        anchors.right: tagText.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        text: rowItem.d ? String(rowItem.d.ip || "") : ""
        color: root.foreground
        opacity: 0.55
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: nameText
        anchors.left: glyph.right
        anchors.verticalCenter: parent.verticalCenter
        // Bounded so a long name elides rather than colliding with the role.
        width: Math.min(implicitWidth, Math.max(0, ipText.x - x - Style.spacing.xl))
        text: {
          if (!rowItem.d) return ""
          return rowItem.isPeer ? String(rowItem.d.name || rowItem.d.ip)
                                : root.displayName(rowItem.d)
        }
        color: rowItem.selected ? root.selText : root.foreground
        opacity: rowItem.isPeer && rowItem.d && !rowItem.d.online ? 0.55 : 1.0
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }

      // The one piece of detail worth keeping on the collapsed line: what the
      // thing is. Everything else waits for selection.
      Text {
        anchors.left: nameText.right
        anchors.leftMargin: Style.spacing.lg
        anchors.right: ipText.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        visible: !rowItem.isPeer
        text: rowItem.d && !rowItem.isPeer ? root.roleSubtitle(rowItem.d) : ""
        color: root.foreground
        opacity: 0.45
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    // Detail block — present only on the selected row.
    Column {
      anchors.top: headLine.bottom
      anchors.topMargin: root.detailPadV
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: root.rowPadH + Style.space(22)
      anchors.rightMargin: root.rowPadH
      visible: rowItem.expanded

      Repeater {
        model: rowItem.fields

        delegate: Item {
          required property var modelData
          width: parent ? parent.width : 0
          height: root.detailRowH

          Text {
            id: fieldKey
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(66)
            text: modelData.k
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.left: fieldKey.right
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.v
            color: root.foreground
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      cursorShape: rowItem.hint !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: {
        root.cursorActive = true
        root.selectedIndex = rowItem.flatIndex
        root.activate(rowItem.flatIndex)
      }
    }

    // Hover-selects, but only on genuine pointer movement. NoButton so clicks
    // fall through to the MouseArea above.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onPositionChanged: function(mouse) {
        if (!hoverGate.moved(this, mouse)) return
        root.cursorActive = true
        root.selectedIndex = rowItem.flatIndex
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-network-scan"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      // Wider than the sibling panels — each row carries a name, an address
      // and a vendor/ports detail line.
      width: Math.min(Style.space(760), panel.width - Style.gapsOut * 2)
      // Sized to the two capped sections, so the card grows with the network
      // only until each list starts scrolling on its own.
      height: Math.min(
        card.contentTopInset + card.contentBottomInset
          + root.headerHeight + root.contentSpacing
          + root.lanBlockH
          + (root.haveTailscale ? root.sectionGap + root.tsBlockH : 0),
        Math.min(panel.height * 0.8, panel.height - Style.bar.sizeHorizontal - Style.gapsOut * 2))
      radius: root.cornerRadius
      // Top-right, tucked under the bar — same spot the first-party
      // network/bluetooth popups land.
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.bar.sizeHorizontal + Style.gapsOut
      anchors.rightMargin: Style.gapsOut
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      clip: true

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          // The chooser owns the keyboard while it's up, so Esc dismisses it
          // rather than the whole panel and list navigation can't run underneath.
          if (root.chooser !== null) {
            if (event.key === Qt.Key_Escape) root.closeChooser()
            else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) root.moveChooser(-1)
            else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) root.moveChooser(1)
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
              root.runAction(root.chooser.options[root.chooserIndex])
            event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_R || event.key === Qt.Key_F5) {
            root.refresh()
            event.accepted = true
          } else if (event.key === Qt.Key_E) {
            root.showAllDetail = !root.showAllDetail
            // Rows just changed height under the selection; put it back in view.
            root.scrollTo(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            root.move(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            root.move(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.move(-root.maxVisibleRows)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.move(root.maxVisibleRows)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectEdge(false)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectEdge(true)
            event.accepted = true
          } else if (event.key === Qt.Key_Y) {
            root.copyAddress(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(root.selectedIndex)
            event.accepted = true
          }
        }
      }

      // ------------------------------------------------------ action chooser
      // Raised only when a row offers more than one action. Centred rather than
      // anchored to the row: rows move as the list scrolls, and a popup that
      // has to track them is a lot of geometry for no benefit.
      Item {
        id: chooserLayer
        anchors.fill: parent
        z: 10
        visible: root.chooser !== null

        // Dims the list so it's obvious it isn't taking input, and swallows
        // clicks: outside the box cancels rather than closing the panel.
        Rectangle {
          anchors.fill: parent
          color: root.background
          opacity: 0.8
        }

        MouseArea {
          anchors.fill: parent
          onClicked: root.closeChooser()
        }

        Rectangle {
          id: chooserBox
          anchors.centerIn: parent
          width: Math.min(Style.space(470), card.width - Style.space(80))
          implicitHeight: chooserCol.implicitHeight + Style.spacing.xxxl * 2
          height: implicitHeight
          radius: root.cornerRadius
          color: root.background
          border.width: Math.max(1, Style.space(2))
          border.color: root.accent

          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            id: chooserCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.xxxl
            anchors.rightMargin: Style.spacing.xxxl
            spacing: Style.spacing.md

            Text {
              width: parent.width
              text: root.chooser ? String(root.chooser.title) : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: "Open how?"
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              bottomPadding: Style.spacing.sm
            }

            Repeater {
              model: root.chooser ? root.chooser.options : []

              delegate: Rectangle {
                id: optRow
                required property int index
                required property var modelData

                readonly property bool current: optRow.index === root.chooserIndex

                width: chooserCol.width
                height: root.titleLineH + Style.spacing.lg * 2
                radius: Style.cornerRadius
                color: optRow.current ? root.selBg : "transparent"

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.lg
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(20)
                  text: optRow.modelData.kind === "web" ? "󰖟" : "󰒋"
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.lg + Style.space(26)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.lg
                  anchors.verticalCenter: parent.verticalCenter
                  text: optRow.modelData.label
                  color: optRow.current ? root.selText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.chooserIndex = optRow.index
                  onClicked: root.runAction(optRow.modelData)
                }
              }
            }

            Text {
              width: parent.width
              topPadding: Style.spacing.sm
              text: "↑↓ choose · ↵ go · esc cancel"
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: panelTitle
            anchors.left: parent.left
            anchors.top: parent.top
            height: root.titleRowH
            verticalAlignment: Text.AlignVCenter
            text: "󰛳  My Network"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          // Scan progress sits beside the title rather than replacing the
          // list, so the fast pass stays readable while the deep pass runs.
          Text {
            anchors.left: panelTitle.right
            anchors.leftMargin: Style.spacing.lg
            anchors.verticalCenter: panelTitle.verticalCenter
            visible: root.scanning
            text: "scanning…"
            color: root.accent
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: copiedNote
            anchors.right: hintText.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: panelTitle.verticalCenter
            color: root.accent
            opacity: 0
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            function show(addr) {
              copiedNote.text = "copied " + addr
              copiedNote.opacity = 0.9
              copiedTimer.restart()
            }

            Behavior on opacity { NumberAnimation { duration: 150 } }

            Timer {
              id: copiedTimer
              interval: 1400
              onTriggered: copiedNote.opacity = 0
            }
          }

          Text {
            id: hintText
            anchors.right: parent.right
            anchors.verticalCenter: panelTitle.verticalCenter
            // Reflects the current mode rather than naming the key's job once,
            // so the panel always says what `e` will do next.
            text: "esc close · r rescan · "
                  + (root.showAllDetail ? "e less detail" : "e all detail")
                  + " · y copy IP · ↵ open"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // The house view on your hardware choices, under the title.
          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: panelTitle.bottom
            text: root.verdictLine()
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.italic: true
            elide: Text.ElideRight
          }
        }

        // Both sections share whatever height the card ended up with, split in
        // proportion to what each asked for. When the card is big enough for
        // both that split hands each exactly its natural height; when the card
        // hits its cap, both shrink together instead of one starving the other.
        Column {
          id: listsCol
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing
          spacing: root.sectionGap

          readonly property real lanH: root.haveTailscale
            ? Math.max(root.headRowH + root.rowH,
                       Math.round((listsCol.height - root.sectionGap)
                                  * root.lanBlockH / (root.lanBlockH + root.tsBlockH)))
            : listsCol.height

          Item {
            width: parent.width
            height: listsCol.lanH

            SectionHeader {
              id: lanHead
              width: parent.width
              label: "Local network"
              // Driven by whether the list actually overflows rather than by a
              // row count: how many rows fit varies with the expanded row.
              note: root.lanNote()
                    + (lanList.contentHeight > lanList.height + 1 ? "  ·  scroll for more" : "")
            }

            Item {
              anchors.top: lanHead.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom

              Text {
                visible: root.devices.length === 0
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.leftMargin: root.rowPadH
                text: root.noJq ? "jq is required for this panel"
                    : root.noNet ? "No active network interface"
                    : !root.loaded ? "Scanning the network…"
                    : "No devices found"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }

              Flickable {
                id: lanList
                anchors.fill: parent
                clip: true
                contentWidth: width
                contentHeight: lanCol.implicitHeight
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds

                Column {
                  id: lanCol
                  width: lanList.width
                  spacing: root.rowGap

                  Repeater {
                    model: root.lanRows

                    // One delegate for both row kinds — a Loader swapping
                    // components would make every row's height depend on when
                    // the Loader resolved, and the scroll maths needs it up
                    // front.
                    delegate: Item {
                      id: lanSlot
                      required property int index
                      required property var modelData

                      readonly property bool isGroup: lanSlot.modelData.kind === "group"

                      width: lanCol.width
                      height: root.rowHeightOf(lanSlot.modelData)

                      GroupCaption {
                        visible: lanSlot.isGroup
                        rowData: lanSlot.modelData
                      }

                      DeviceRow {
                        visible: !lanSlot.isGroup
                        flatIndex: lanSlot.index
                        // Null on a caption row: hidden items still evaluate
                        // their bindings, so don't hand it a row it can't read.
                        rowData: lanSlot.isGroup ? null : lanSlot.modelData
                      }
                    }
                  }
                }
              }

              ScrollHint { list: lanList }
            }
          }

          Item {
            visible: root.haveTailscale
            width: parent.width
            height: root.haveTailscale ? listsCol.height - root.sectionGap - listsCol.lanH : 0

            SectionHeader {
              id: tsHead
              width: parent.width
              label: "Tailscale"
              note: root.tsNote()
                    + (tsList.contentHeight > tsList.height + 1 ? "  ·  scroll for more" : "")
            }

            Item {
              anchors.top: tsHead.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom

              Text {
                visible: root.peers.length === 0
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.leftMargin: root.rowPadH
                text: root.tsState !== "" ? "Not connected to a tailnet" : "No peers"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }

              Flickable {
                id: tsList
                anchors.fill: parent
                clip: true
                contentWidth: width
                contentHeight: tsCol.implicitHeight
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds

                Column {
                  id: tsCol
                  width: tsList.width
                  spacing: root.rowGap

                  Repeater {
                    model: root.tsRows

                    delegate: DeviceRow {
                      required property int index
                      required property var modelData
                      flatIndex: root.lanCount + index
                      rowData: modelData
                    }
                  }
                }
              }

              ScrollHint { list: tsList }
            }
          }
        }
      }
    }
  }
}
