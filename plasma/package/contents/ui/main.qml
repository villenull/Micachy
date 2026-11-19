import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.plasmoid

import "backend.js" as Backend

// Micachy's Plasma applet: one panel icon, one popup.
//
// The same control surface as quickshell/Panel.qml, redrawn with Plasma's own
// components, and under the same rule: everything with a decision in it lives
// in `micachy-ctl`. This file reads `status --json`, draws it, and hands every
// click back to a subprocess.
//
// Three things differ from the Quickshell panel, each for a reason:
//
//   * It does not supervise the daemons. On Plasma they are systemd user
//     units (cachyos/install-units), and a second supervisor would only race
//     the first for the pidfile.
//   * State is polled, not watched. Plasma's QML has no file watcher to hang
//     a refresh on, so a change made from a keybinding shows up on the next
//     poll rather than within a frame. Clicks made here re-read at once.
//   * There is no "follow the theme" swatch. That colour is resolved from
//     Omarchy's theme directory, which does not exist here.
PlasmoidItem {
    id: root

    // ---- state -------------------------------------------------------------

    // The parsed `micachy-ctl status --json` document, or null before the
    // first successful read. Null is not "everything is off": it is what "no
    // reading yet" looks like, and the popup says so.
    property var status: null
    // Sticky until a good read clears it, so one failed poll does not flicker
    // the popup.
    property bool backendFailed: false

    readonly property bool lightingActive: status ? status.lighting_active === true : false
    readonly property bool displayActive: status ? status.display_active === true : false
    readonly property bool linked: status ? status.linked === true : true
    readonly property int speedStops: status && status.speed_stops ? status.speed_stops : 5
    readonly property string daemonNote: (status && status.daemon_note) ? String(status.daemon_note) : ""

    readonly property var targetKeys: {
        if (!status || !status.targets) return []
        return Object.keys(status.targets)
    }

    readonly property string effectSummary: {
        if (!status || targetKeys.length === 0) return "—"
        var effects = targetKeys.map(function (k) { return status.targets[k].effect })
        var same = effects.every(function (e) { return e === effects[0] })
        return (linked || same) ? effects[0] : effects.join(" / ")
    }

    readonly property bool lightsLive: lightingActive && effectSummary !== "off"

    // ---- what the popup can set --------------------------------------------

    // `effects.EFFECTS`, in its order: the order the cells are drawn in and
    // the order the 1-6/0 keys number them. tests/test_plasma_applet.py holds
    // this list to the Python one.
    readonly property var effects: ["static", "rainbow", "spectrum", "chase",
                                    "breathing", "unhinged", "off"]

    // The same fixed swatches as the Quickshell panel, minus its theme chip.
    readonly property var swatches: ["#ffffff", "#ff0000", "#ff5a00", "#00ff3c",
                                     "#00c8ff", "#1e64ff", "#ff00a0"]

    // One entry per control block. An empty `key` means the command is issued
    // without `--zone`, the every-target default: linked takes that path so
    // every zone's stored state agrees with the one block on screen, and
    // unlinking later reveals what was being shown. `source` is the entry a
    // block reads; while linked that is the first zone, which is what the
    // daemon renders every other zone from.
    readonly property var blocks: {
        if (backendFailed || !status || targetKeys.length === 0) return []
        if (linked) return [{
            key: "",
            source: targetKeys[0],
            title: "All zones",
            subtitle: targetKeys.join(" · ")
        }]
        return targetKeys.map(function (k) {
            return { key: k, source: k, title: k.replace(/_/g, " "), subtitle: "" }
        })
    }

    function targetFor(block) {
        if (!block || !status || !status.targets) return null
        return status.targets[block.source] || null
    }

    function targetColour(target) {
        if (!target || !target.colour) return Kirigami.Theme.highlightColor
        var c = target.colour
        return Qt.rgba(c[0] / 255, c[1] / 255, c[2] / 255, 1)
    }

    // Which swatch the zone is on, or -1 for a colour set from somewhere else.
    // Marking nothing is more honest than marking the nearest.
    function selectedSwatch(target) {
        if (!target || !target.colour || target.follows_theme) return -1
        var hex = "#" + target.colour.slice(0, 3).map(function (v) {
            var s = Math.max(0, Math.min(255, Math.round(v))).toString(16)
            return s.length < 2 ? "0" + s : s
        }).join("")
        return swatches.indexOf(hex)
    }

    // ---- talking to the backend --------------------------------------------

    // Plasma's only way to run a program from QML is the `executable` data
    // engine, and it takes one string that it hands to a shell. So unlike the
    // Quickshell panel, which passes an argv, every argument here is quoted:
    // zone names come from the user's config and `#ffffff` is a comment to sh.
    function quote(arg) {
        return "'" + String(arg).replace(/'/g, "'\\''") + "'"
    }

    readonly property string backendDir: Backend.dir !== ""
        ? Backend.dir
        : String(Qt.resolvedUrl("../../../../bin")).replace(/^file:\/\//, "")

    // Named interpreter and -I -S, as everywhere else in this project: nothing
    // looked up on $PATH, no user site directory; the backend is stdlib-only.
    function ctl(args) {
        return "/usr/bin/python3 -I -S " + quote(backendDir + "/micachy-ctl")
            + " " + args.map(quote).join(" ")
    }

    readonly property string statusCommand: ctl(["status", "--json"])

    property bool statusRunning: false
    property bool actionRunning: false
    // Only the most recent click is kept while one is in flight: a burst
    // through several speed stops wants to end where the user stopped.
    property var pendingAction: null

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: function (source, data) {
            // A source stays connected, and would re-report, until it is
            // dropped; dropping it is also what lets the same command line
            // run again on the next poll.
            disconnectSource(source)

            if (source === root.statusCommand) {
                root.statusRunning = false
                root.statusFinished(data["exit code"], data["stdout"])
                return
            }

            root.actionRunning = false
            // Re-read at once so a click feels like it did something.
            root.refresh()
            if (root.pendingAction) {
                var next = root.pendingAction
                root.pendingAction = null
                root.run(next)
            }
        }
    }

    function statusFinished(exitCode, stdout) {
        if (exitCode !== 0) {
            // A shell reports a missing interpreter or script as a non-zero
            // exit, so this one branch covers "could not start" as well.
            if (!root.status) root.backendFailed = true
            return
        }
        try {
            var parsed = JSON.parse(String(stdout || ""))
            if (parsed && typeof parsed === "object") {
                root.status = parsed
                root.backendFailed = false
            }
        } catch (e) {
            // Malformed output is not worth clearing a good reading over:
            // keep what is on screen and try again on the next tick.
            console.warn("micachy: could not parse status", e)
        }
    }

    function refresh() {
        if (statusRunning) return
        statusRunning = true
        executable.connectSource(statusCommand)
    }

    // Serialised, because two `micachy-ctl` writes racing each other is the
    // interleaving its atomic write exists to prevent.
    function run(args) {
        if (actionRunning) {
            pendingAction = args
            return
        }
        actionRunning = true
        executable.connectSource(ctl(args))
    }

    // Closed, the icon only has to notice the lights going off or the daemon
    // dying, which is not a per-second question. Open, the popup is drawn
    // from this.
    Timer {
        interval: root.expanded ? 2000 : 30000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    onExpandedChanged: if (expanded) refresh()

    // ---- acting ------------------------------------------------------------

    function zoneArgs(block) {
        return (block && block.key !== "") ? ["--zone", block.key] : []
    }

    function chooseEffect(block, index) {
        if (!block || index < 0 || index >= effects.length) return
        run(["effect", effects[index]].concat(zoneArgs(block)))
    }

    function chooseColour(block, index) {
        if (!block || index < 0 || index >= swatches.length) return
        run(["colour", swatches[index]].concat(zoneArgs(block)))
    }

    // Absolute rather than stepped: clicking the fourth of five segments has
    // to land on four.
    function chooseSpeed(block, index) {
        if (!block || index < 0 || index >= speedStops) return
        run(["speed", "set", String(index + 1)].concat(zoneArgs(block)))
    }

    // ---- panel icon --------------------------------------------------------

    // The lit and unlit bulb are the one piece of state worth reading without
    // opening anything: unlit means the daemon is stopped, the effect is
    // `off`, or there is no reading yet.
    Plasmoid.icon: (backendFailed || !lightsLive) ? "redshift-status-off" : "redshift-status-on"

    toolTipMainText: "Micachy"
    toolTipSubText: {
        if (backendFailed) return "Backend failed to run"
        if (!status) return "No reading yet"
        var parts = [lightingActive ? effectSummary : "lighting daemon stopped"]
        var s = status.sensors
        if (s && s.cpu_temp != null) parts.push("CPU " + Math.round(s.cpu_temp) + "°C")
        if (s && s.gpu_temp != null) parts.push("GPU " + Math.round(s.gpu_temp) + "°C")
        if (s && s.cpu_fan_rpm != null) parts.push(Math.round(s.cpu_fan_rpm) + " rpm")
        return parts.join(" · ")
    }

    // Middle-click on the icon links and unlinks, as on the Quickshell bar.
    Plasmoid.onSecondaryActivated: run(["link", "toggle"])

    // ---- popup -------------------------------------------------------------

    fullRepresentation: PlasmaExtras.Representation {
        id: popup

        // Wide enough for seven effect cells to carry their own names, which
        // is the only thing in here that sets a width.
        Layout.minimumWidth: Kirigami.Units.gridUnit * 26
        Layout.preferredWidth: Kirigami.Units.gridUnit * 26
        // Unlinked, this is one block per zone, so the height follows the
        // content up to a cap and scrolls beyond it.
        Layout.minimumHeight: Kirigami.Units.gridUnit * 10
        Layout.preferredHeight: Math.min(column.implicitHeight + Kirigami.Units.largeSpacing * 2,
                                         Kirigami.Units.gridUnit * 40)
        Layout.maximumHeight: Kirigami.Units.gridUnit * 40

        collapseMarginsHint: true
        focus: true

        // The Quickshell panel's letters, so muscle memory carries over. The
        // effect numbers act on the first block, which while linked is the
        // only one there is.
        Keys.onPressed: function (event) {
            var key = event.text.toLowerCase()
            if (key === "d") root.run(["display", "toggle"])
            else if (key === "u") root.run(["link", "toggle"])
            else if (key === "+" || key === "=") root.run(["speed", "+"])
            else if (key === "-") root.run(["speed", "-"])
            else if (key >= "1" && key <= "6" && root.blocks.length > 0)
                root.chooseEffect(root.blocks[0], parseInt(key) - 1)
            else if (key === "0" && root.blocks.length > 0)
                root.chooseEffect(root.blocks[0], root.effects.length - 1)
            else return
            event.accepted = true
        }

        header: PlasmaExtras.PlasmoidHeading {
            contentItem: Kirigami.Heading {
                level: 3
                text: "Lighting"
                leftPadding: Kirigami.Units.smallSpacing
            }
        }

        contentItem: PlasmaComponents.ScrollView {
            id: scroll
            contentWidth: availableWidth

            ColumnLayout {
                id: column
                width: scroll.availableWidth - Kirigami.Units.largeSpacing * 2
                x: Kirigami.Units.largeSpacing
                y: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.largeSpacing

                // A sentence rather than an empty popup. The next successful
                // poll clears it.
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    visible: root.backendFailed
                    text: "Micachy backend failed to run.\nReinstall with cachyos/install-applet from the checkout."
                    wrapMode: Text.WordWrap
                }

                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    visible: !root.backendFailed && !root.status
                    text: "Reading…"
                    opacity: 0.6
                }

                // Above everything it applies to, because it decides how much
                // of the rest there is: one block, or one per zone.
                ToggleRow {
                    visible: !root.backendFailed && root.status !== null
                    label: "Link all zones"
                    description: root.linked ? "driven together" : "driven independently"
                    checked: root.linked
                    onClicked: root.run(["link", "toggle"])
                }

                // Stated before anything below it is touched: a frozen strip
                // answers every control here identically. The daemon's own
                // note (the udev hint, e.g.) wins when it left one.
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    visible: !root.backendFailed && root.status !== null && !root.lightingActive
                    text: root.daemonNote !== "" ? root.daemonNote
                        : "Lighting daemon stopped — LEDs frozen.\nStart it with: systemctl --user start micachy-lightd"
                    wrapMode: Text.WordWrap
                    color: Kirigami.Theme.negativeTextColor
                }

                Repeater {
                    model: root.blocks

                    ZoneBlock { Layout.fillWidth: true }
                }

                Kirigami.Separator {
                    Layout.fillWidth: true
                    visible: !root.backendFailed && root.status !== null
                }

                ToggleRow {
                    visible: !root.backendFailed && root.status !== null
                    label: "Cooler display"
                    // The display has no off command in its protocol, so
                    // "off" means the telemetry stream stopped and it blanks
                    // itself about fifty seconds later.
                    description: root.displayActive ? "streaming telemetry" : "blanks ~50s after stopping"
                    checked: root.displayActive
                    onClicked: root.run(["display", "toggle"])
                }

                Item { Layout.preferredHeight: 1 }
            }
        }
    }

    // ---- pieces ------------------------------------------------------------

    // A label, a line under it, and a switch that shows the backend's value.
    //
    // The MouseArea sits over the whole row, switch included, on purpose. A
    // Switch that takes its own click flips itself and drops its `checked`
    // binding, after which it shows what was clicked rather than what the
    // backend did. Kept out of reach, it stays a readout of `status`.
    component ToggleRow: Item {
        id: toggle

        property string label: ""
        property string description: ""
        property bool checked: false
        signal clicked()

        Layout.fillWidth: true
        implicitHeight: toggleLayout.implicitHeight

        RowLayout {
            id: toggleLayout
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Kirigami.Units.largeSpacing

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: toggle.label
                }

                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: toggle.description
                    font: Kirigami.Theme.smallFont
                    opacity: 0.6
                }
            }

            PlasmaComponents.Switch {
                checked: toggle.checked
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: toggle.clicked()
        }
    }

    // The frame every clickable cell shares: outlined when it is the current
    // value, tinted while hovered.
    component Cell: Rectangle {
        id: cellFrame

        property bool selected: false
        property bool outlined: true
        signal clicked()

        radius: Kirigami.Units.cornerRadius
        color: cellMouse.containsMouse
            ? Qt.alpha(Kirigami.Theme.highlightColor, 0.25)
            : (selected ? Qt.alpha(Kirigami.Theme.highlightColor, 0.12) : "transparent")
        border.width: outlined || selected ? 1 : 0
        border.color: selected ? Kirigami.Theme.highlightColor
                               : Qt.alpha(Kirigami.Theme.textColor, 0.15)

        MouseArea {
            id: cellMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: cellFrame.clicked()
        }
    }

    // Three LEDs running the effect, in the zone's own colour. Seven names are
    // hard to tell apart in words; a preview is the shortest description
    // there is. Every effect derives from one looping clock, and the clock
    // only runs while the popup is open.
    component LedStrip: Item {
        id: strip

        property string effect: ""
        property color baseColour: "white"

        readonly property bool animated: effect !== "static" && effect !== "off"
        property real clock: 0

        readonly property int period: {
            if (effect === "chase") return 1500
            if (effect === "unhinged") return 900
            if (effect === "breathing") return 3000
            return 3400
        }

        NumberAnimation on clock {
            running: root.expanded && strip.animated
            loops: Animation.Infinite
            from: 0
            to: 1
            duration: strip.period
        }

        function segmentColour(i) {
            var c = strip.clock
            switch (strip.effect) {
            // A hue wave in space as well as in time.
            case "rainbow":
                return Qt.hsva((c + i / 3) % 1, 0.85, 1, 1)
            // Quantised to five stops, or it would draw the same picture as
            // rainbow.
            case "spectrum":
                return Qt.hsva(Math.floor(c * 5) / 5, 0.85, 1, 1)
            // Steppy and out of step between segments, on purpose.
            case "unhinged":
                return Qt.hsva((Math.floor(c * 6) * 0.37 + i * 0.21) % 1, 1, 1, 1)
            case "off":
                return Qt.alpha(Kirigami.Theme.textColor, 0.18)
            default:
                return strip.baseColour
            }
        }

        function segmentOpacity(i) {
            var c = strip.clock
            if (strip.effect === "chase") {
                var d = ((c * 3) - i + 3) % 3
                return d < 1 ? 0.2 + 0.8 * (1 - d) : 0.2
            }
            if (strip.effect === "breathing")
                return 0.2 + 0.8 * (0.5 - 0.5 * Math.cos(c * 2 * Math.PI))
            return 1
        }

        Row {
            anchors.fill: parent
            spacing: 2

            Repeater {
                model: 3

                Rectangle {
                    required property int index
                    width: (strip.width - 4) / 3
                    height: strip.height
                    radius: 1
                    color: strip.segmentColour(index)
                    opacity: strip.segmentOpacity(index)
                }
            }
        }
    }

    // Everything one zone can be set to, in one block: effect, colour, speed.
    // Linked draws exactly one of these for every zone at once; unlinked
    // draws one each.
    component ZoneBlock: ColumnLayout {
        id: zone

        required property var modelData

        readonly property var target: root.targetFor(modelData)
        readonly property color baseColour: root.targetColour(target)

        spacing: Kirigami.Units.smallSpacing

        Kirigami.Separator { Layout.fillWidth: true }

        RowLayout {
            Layout.fillWidth: true

            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: zone.modelData.title
                font.bold: true
            }

            PlasmaComponents.Label {
                text: zone.target ? zone.target.effect : "—"
                color: Kirigami.Theme.highlightColor
            }
        }

        // Only the linked block has one: it names the zones this single set
        // of controls is driving.
        PlasmaComponents.Label {
            Layout.fillWidth: true
            visible: zone.modelData.subtitle !== ""
            text: zone.modelData.subtitle
            elide: Text.ElideRight
            font: Kirigami.Theme.smallFont
            opacity: 0.6
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            uniformCellSizes: true

            Repeater {
                model: root.effects

                Cell {
                    id: effectCell

                    required property int index
                    required property string modelData

                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 2.6
                    selected: zone.target ? zone.target.effect === modelData : false
                    onClicked: root.chooseEffect(zone.modelData, index)

                    Column {
                        anchors.centerIn: parent
                        width: parent.width - Kirigami.Units.smallSpacing * 2
                        spacing: Kirigami.Units.smallSpacing

                        LedStrip {
                            width: parent.width
                            height: Kirigami.Units.smallSpacing * 2
                            effect: effectCell.modelData
                            baseColour: zone.baseColour
                        }

                        // The effect's real name, the word `micachy-ctl
                        // effect` takes. Fitted rather than elided, so only
                        // the long names shrink.
                        Text {
                            width: parent.width
                            text: effectCell.modelData
                            horizontalAlignment: Text.AlignHCenter
                            fontSizeMode: Text.HorizontalFit
                            minimumPixelSize: 6
                            // A pixel size, not Kirigami's smallFont: that
                            // one is set in points, and HorizontalFit only
                            // shrinks from a pixel size.
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.62)
                            color: Kirigami.Theme.textColor
                            opacity: effectCell.selected ? 1 : 0.6
                        }
                    }
                }
            }
        }

        // Hidden when the effect ignores colour, on the backend's own word:
        // `takes_colour` is computed in `ctl.cmd_status`, so there is no
        // second copy of that set here to fall out of date.
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            visible: zone.target ? zone.target.takes_colour === true : false

            PlasmaComponents.Label {
                text: "colour"
                font: Kirigami.Theme.smallFont
                opacity: 0.6
            }

            Repeater {
                model: root.swatches

                Cell {
                    id: swatchCell

                    required property int index
                    required property string modelData

                    Layout.preferredWidth: Kirigami.Units.gridUnit * 1.6
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 1.6
                    outlined: false
                    selected: root.selectedSwatch(zone.target) === index
                    onClicked: root.chooseColour(zone.modelData, index)

                    Rectangle {
                        anchors.centerIn: parent
                        width: Kirigami.Units.gridUnit
                        height: width
                        radius: width / 2
                        color: swatchCell.modelData
                        border.width: 1
                        border.color: Qt.rgba(0, 0, 0, 0.35)
                    }
                }
            }

            Item { Layout.fillWidth: true }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            visible: zone.target ? zone.target.takes_speed === true : false

            RowLayout {
                Layout.fillWidth: true

                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: "speed"
                    font: Kirigami.Theme.smallFont
                    opacity: 0.6
                }

                PlasmaComponents.Label {
                    text: (zone.target ? zone.target.speed_stop : "—") + " / " + root.speedStops
                    font: Kirigami.Theme.smallFont
                }
            }

            // Discrete segments rather than a slider, because the backend has
            // exactly this many stops and a continuous track would be a
            // picture of something that does not exist.
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                uniformCellSizes: true

                Repeater {
                    model: root.speedStops

                    Cell {
                        id: speedCell

                        required property int index

                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit
                        outlined: false
                        onClicked: root.chooseSpeed(zone.modelData, index)

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: 2
                            height: Kirigami.Units.smallSpacing
                            radius: height / 2
                            color: (zone.target && speedCell.index < zone.target.speed_stop)
                                ? Kirigami.Theme.highlightColor
                                : Qt.alpha(Kirigami.Theme.textColor, 0.18)
                        }
                    }
                }
            }
        }
    }
}
