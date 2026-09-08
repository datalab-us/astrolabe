import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "components"
import "Model.js" as Model
import "K8sGraph.js" as K8sGraph

// Fullscreen topology overlay: deterministic column graph of workloads +
// network edges, with search, upstream/downstream reach, a detail passport,
// an in-plugin output viewer (logs / describe), and a managed port-forward
// with a toolbar status pill. Summoned from the bar widget via
// `omarchy-shell shell toggle <id>`.
Item {
  id: root

  property bool opened: false
  property string context: ""
  property string selectedNamespace: "__all"
  property var namespaces: []
  property var hiddenKinds: ({}) // kind -> true
  property string searchText: ""
  property var searchHits: []
  property string selectedId: ""
  property string reachMode: "none" // none | up | down
  property var reachIds: ({})
  property string reachInfo: ""
  property real zoom: 1.0

  // Full-cluster IR + filtered view.
  property var fullGraph: null
  property var viewNodes: []   // [{node,x,y}]
  property var viewEdges: []
  property var viewWarnings: []
  property var layoutSize: ({ w: 100, h: 100 })
  property string loadState: "loading" // loading | ready | error | empty
  property string loadError: ""
  property string loadDetail: ""
  property string updatedAt: ""

  // In-plugin output viewer (logs / describe output, no terminal).
  property string outputTitle: ""
  property var outputCmdArgs: []
  property string outputTerminalCmd: ""
  property string outputBody: ""
  property bool outputBusy: false
  property bool outputVisible: false
  property string outputCopiedMsg: ""

  // Managed port-forward (one at a time, owned by the overlay).
  property bool pfActive: false
  property string pfKey: ""
  property string pfLabel: ""
  property string pfError: ""
  property bool pfStopping: false

  readonly property bool hasHighlight: reachMode !== "none" || searchHits.length > 0
  readonly property int nodeCap: 800

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}
    // No namespace in payload preserves the current filter (e.g. reopening
    // from the bar pill keeps your place); pass {"namespace":"__all"} to reset.
    if (payload.namespace) root.selectedNamespace = payload.namespace
    root.opened = true
    root.reachMode = "none"
    root.selectedId = ""
    root.searchText = ""
    root.searchHits = []
    searchBar.clear()
    graphView.contentX = 0
    graphView.contentY = 0
    fullPoller.refresh()
    nodesPoller.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (root.pfActive) root.stopPortForward()
    root.hideOutput()
    root.opened = false
  }
  function toggle() { if (root.opened) root.close(); else root.open("{}") }

  // Introspection for live testing via `omarchy-shell shell call <id> debugState`.
  function debugState() {
    return JSON.stringify({
      opened: root.opened,
      context: root.context,
      selectedNamespace: root.selectedNamespace,
      namespaces: root.namespaces,
      contentX: graphView.contentX,
      contentY: graphView.contentY,
      loadState: root.loadState,
      nodes: root.viewNodes.length,
      edges: root.viewEdges.length,
      zoom: root.zoom,
      selectedId: root.selectedId
    })
  }

  // --- data ---------------------------------------------------------------
  function onFullData(text, exitCode, err) {
    if (exitCode !== 0) {
      root.loadState = "error"
      var kind = Model.classifyError(exitCode, err, text)
      root.loadError = errorTitle(kind)
      root.loadDetail = String(err || text || "").trim().split("\n").slice(0, 4).join("\n")
      return
    }
    var parsed = Model.safeParseJson(text)
    if (!parsed.ok) {
      root.loadState = "error"
      root.loadError = "Could not parse kubectl output"
      root.loadDetail = parsed.error
      return
    }
    root.lastBundle = Model.splitMixedList(parsed.data)
    mergeGraphs()
  }

  property var lastBundle: null
  property var lastNodes: []

  function onNodesData(text, exitCode) {
    if (exitCode !== 0) return
    var parsed = Model.safeParseJson(text)
    if (!parsed.ok) return
    root.lastNodes = Model.listItems(parsed.data)
    mergeGraphs()
  }

  function mergeGraphs() {
    if (!root.lastBundle) return
    var bundle = root.lastBundle
    bundle.nodes = root.lastNodes
    root.fullGraph = K8sGraph.buildGraph(bundle)
    collectNamespaces()
    applyView()
    var d = new Date()
    root.updatedAt = Qt.formatTime(d, "hh:mm:ss")
  }

  function collectNamespaces() {
    var set = {}
    var nodes = root.fullGraph.nodes
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].namespace !== "") set[nodes[i].namespace] = true
    }
    var list = Object.keys(set).sort()
    root.namespaces = list
    if (root.selectedNamespace !== "__all" && !set[root.selectedNamespace]) {
      root.selectedNamespace = "__all"
    }
  }

  // --- view ---------------------------------------------------------------
  function workloadKinds() { return ["Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"] }

  function kindVisible(kind) {
    if (root.hiddenKinds[kind]) return false
    if (root.hiddenKinds["__workload"]) {
      var w = workloadKinds()
      for (var i = 0; i < w.length; i++) { if (w[i] === kind) return false }
    }
    return true
  }

  function applyView() {
    if (!root.fullGraph) return
    var nodes = []
    var keep = {}
    var all = root.fullGraph.nodes
    var i
    for (i = 0; i < all.length; i++) {
      var n = all[i]
      if (root.selectedNamespace !== "__all" && n.namespace !== "" && n.namespace !== root.selectedNamespace) continue
      if (n.kind !== "Node" && !kindVisible(n.kind)) continue
      nodes.push(n)
      keep[n.id] = true
    }
    var edges = []
    var allEdges = root.fullGraph.edges
    for (i = 0; i < allEdges.length; i++) {
      if (keep[allEdges[i].from] && keep[allEdges[i].to]) edges.push(allEdges[i])
    }
    var sub = { nodes: nodes, edges: edges }
    var l = K8sGraph.layout(sub, {})
    var view = []
    for (i = 0; i < nodes.length; i++) {
      var pos = l.positions[nodes[i].id]
      if (pos) view.push({ node: nodes[i], x: pos.x, y: pos.y })
    }
    // Node cap: keep workload columns complete, trim pods beyond the cap.
    var truncated = 0
    if (view.length > root.nodeCap) {
      var trimmed = []
      for (i = 0; i < view.length; i++) {
        if (view[i].node.kind !== "Pod" || trimmed.length < root.nodeCap) trimmed.push(view[i])
        else truncated++
      }
      view = trimmed
    }
    root.viewNodes = view
    root.viewEdges = edges
    root.layoutSize = l.size
    var warns = []
    var gw = root.fullGraph.warnings
    for (i = 0; i < gw.length; i++) { if (keep[gw[i].node]) warns.push(gw[i]) }
    root.viewWarnings = warns
    if (view.length === 0) root.loadState = "empty"
    else if (root.loadState !== "ready") root.loadState = "ready"
    if (root.loadState === "ready" || root.loadState === "empty") {
      if (truncated > 0) {
        root.viewWarnings = warns.concat([{ type: "truncated", node: "",
          text: truncated + " pods hidden by node cap — filter by namespace" }])
      }
    }
    updateHighlight()
    if (root.selectedId !== "" && !keep[root.selectedId]) root.selectedId = ""
  }

  function updateHighlight() {
    if (root.reachMode !== "none" && root.selectedId !== "") {
      var sub = { nodes: [], edges: root.viewEdges }
      for (var i = 0; i < root.viewNodes.length; i++) sub.nodes.push(root.viewNodes[i].node)
      var r = K8sGraph.reach(sub, root.selectedId, root.reachMode === "up" ? "up" : "down")
      var map = {}
      for (var j = 0; j < r.ids.length; j++) map[r.ids[j]] = true
      root.reachIds = map
      var dir = root.reachMode === "up" ? "upstream" : "downstream"
      root.reachInfo = dir + ": " + r.ids.length + " nodes · " + r.links + " links · " + r.maxHops + " hops"
    } else if (root.searchHits.length > 0) {
      var map2 = {}
      for (var k = 0; k < root.searchHits.length; k++) map2[root.searchHits[k]] = true
      root.reachIds = map2
      root.reachInfo = root.searchHits.length + " match(es)"
    } else {
      root.reachIds = {}
      root.reachInfo = ""
    }
  }

  function onSearch(text) {
    root.searchText = text
    if (text.trim() === "") {
      root.searchHits = []
    } else {
      var nodes = []
      for (var i = 0; i < root.viewNodes.length; i++) nodes.push(root.viewNodes[i].node)
      root.searchHits = K8sGraph.searchNodes(nodes, text)
    }
    updateHighlight()
  }

  function selectNode(id) {
    if (root.selectedId === id) {
      root.selectedId = ""
      root.reachMode = "none"
    } else {
      root.selectedId = id
    }
    updateHighlight()
  }

  function cycleReach() {
    if (root.selectedId === "") return
    root.reachMode = root.reachMode === "none" ? "down" : root.reachMode === "down" ? "up" : "none"
    updateHighlight()
  }

  function selectedNode() {
    for (var i = 0; i < root.viewNodes.length; i++) {
      if (root.viewNodes[i].node.id === root.selectedId) return root.viewNodes[i].node
    }
    return null
  }

  function relatedEdges(dir) {
    var out = []
    for (var i = 0; i < root.viewEdges.length; i++) {
      var e = root.viewEdges[i]
      if (dir === "in" && e.to === root.selectedId) out.push(e)
      if (dir === "out" && e.from === root.selectedId) out.push(e)
    }
    return out
  }

  function kindAccent(kind) {
    if (kind === "Ingress") return "#FBBF24"
    if (kind === "Service") return "#22D3EE"
    if (kind === "Pod") return "#A78BFA"
    if (kind === "Node") return "#94A3B8"
    return "#34D399" // workloads + replicasets
  }

  function errorTitle(kind) {
    if (kind === "no-kubectl") return "kubectl not found"
    if (kind === "no-kubeconfig") return "No kubeconfig"
    if (kind === "unreachable") return "Cluster unreachable"
    if (kind === "forbidden") return "Access denied (RBAC)"
    return "kubectl failed"
  }

  function cycleNamespace(dir) {
    var list = ["__all"].concat(root.namespaces)
    var idx = list.indexOf(root.selectedNamespace)
    idx = (idx + dir + list.length) % list.length
    root.selectedNamespace = list[idx]
    applyView()
  }

  function toggleKindFilter(key) {
    var h = {}
    for (var k in root.hiddenKinds) h[k] = root.hiddenKinds[k]
    if (h[key]) delete h[key]
    else h[key] = true
    root.hiddenKinds = h
    applyView()
  }

  function runInTerminal(cmd) {
    if (!cmd) return
    Quickshell.execDetached(["xdg-terminal-exec", "bash", "-c", cmd + "; echo '--- exit: $? ---'; exec bash"])
  }

  function copyToClipboard(value) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Model.shellQuote(value) + " | wl-copy"])
  }

  // --- in-plugin output viewer (logs / describe) ---------------------------
  function showOutput(title, cmdArgs, terminalCmd) {
    if (!cmdArgs || cmdArgs.length === 0) return
    root.outputTitle = String(title || "Output")
    root.outputCmdArgs = cmdArgs
    root.outputTerminalCmd = String(terminalCmd || Model.argsToString(cmdArgs))
    root.outputBody = ""
    root.outputBusy = true
    root.outputVisible = true
    root.outputCopiedMsg = ""
    outputProc.command = cmdArgs
    outputProc.running = true
  }

  function hideOutput() {
    root.outputVisible = false
    root.outputBusy = false
    root.outputCopiedMsg = ""
  }

  function copyOutputText(value, what) {
    if (!value) return
    root.copyToClipboard(value)
    root.outputCopiedMsg = what + " copied ✓"
    outputCopyReset.restart()
  }

  // --- managed port-forward -------------------------------------------------
  // One forward at a time: localhost:8080 -> the target's service port.
  // Status shows in the toolbar pill while connected; stopping is one click
  // (✕). The forward is stopped when the overlay closes so no orphan kubectl
  // is left behind.
  function pfRemotePort(n) {
    if (n && n.detail) {
      var p = n.detail.ports
      if (typeof p === "string") {
        var first = parseInt(String(p).split(",")[0], 10)
        if (!isNaN(first) && first > 0) return first
      } else if (Array.isArray(p) && p.length > 0) {
        var v = parseInt(p[0], 10)
        if (!isNaN(v) && v > 0) return v
      }
    }
    return 80
  }

  function togglePortForward() {
    if (root.pfActive) {
      root.stopPortForward()
      return
    }
    var n = root.selectedNode()
    if (!n || (n.kind !== "Service" && n.kind !== "Pod")) return
    var tgt = n.kind === "Service" ? "svc/" + n.name : n.name
    var remote = root.pfRemotePort(n)
    root.pfStopping = false
    root.pfKey = n.kind + "/" + (n.namespace || "") + "/" + n.name
    root.pfLabel = "localhost:8080 → " + tgt + " (" + n.namespace + ":" + remote + ")"
    root.pfError = ""
    pfProc.command = Model.portForwardArgs(n.namespace, tgt, 8080, remote)
    pfProc.running = true
  }

  function stopPortForward() {
    root.pfStopping = true
    root.pfActive = false
    root.pfKey = ""
    root.pfLabel = ""
    root.pfError = ""
    if (pfProc.running) pfProc.running = false
    else root.pfStopping = false
  }

  // --- collectors ---------------------------------------------------------
  K8sPoller {
    id: fullPoller
    command: ["kubectl", "get", "deploy,rs,sts,ds,job,cronjobs,pods,svc,endpointslices,ingress",
      "-A", "-o", "json"]
    interval: 15000
    active: root.opened
    onFinished: function(text, code, err) { root.onFullData(text, code, err) }
  }

  K8sPoller {
    id: nodesPoller
    command: ["kubectl", "get", "nodes", "-o", "json"]
    interval: 60000
    active: root.opened
    onFinished: function(text, code) { root.onNodesData(text, code) }
  }

  K8sPoller {
    id: ctxPoller
    command: ["kubectl", "config", "current-context"]
    interval: 60000
    active: root.opened
    onFinished: function(text, code) {
      if (code === 0) root.context = String(text || "").trim()
    }
  }

  // One-shot runner for the output viewer (logs / describe).
  Process {
    id: outputProc
    stdout: StdioCollector {
      id: outputOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: outputErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.outputBusy = false
      var out = String(outputOut.text || "")
      var err = String(outputErr.text || "").trim()
      if (exitCode !== 0 && out.trim() === "") {
        root.outputBody = "exit " + exitCode + (err !== "" ? "\n" + err : "")
      } else if (err !== "") {
        root.outputBody = out + "\n--- stderr ---\n" + err
      } else {
        root.outputBody = out === "" ? "(no output)" : out
      }
    }
  }

  Timer {
    id: outputCopyReset
    interval: 1500
    onTriggered: root.outputCopiedMsg = ""
  }

  // Long-running kubectl port-forward owned by the overlay.
  Process {
    id: pfProc
    stdout: StdioCollector {
      id: pfOut
      waitForEnd: false
    }
    stderr: StdioCollector {
      id: pfErr
      waitForEnd: false
    }
    onStarted: {
      root.pfActive = true
      root.pfError = ""
    }
    onExited: function(exitCode) {
      if (root.pfActive && !root.pfStopping) {
        var e = String(pfErr.text || "").trim().split("\n").filter(function(l) {
          return l.trim() !== ""
        }).slice(-2).join("\n")
        root.pfError = e !== "" ? e : "port-forward exited (" + exitCode + ")"
      }
      root.pfActive = false
      root.pfKey = ""
      root.pfLabel = ""
      root.pfStopping = false
    }
  }

  // --- window -------------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-astrolabe-k8s"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      id: card
      anchors.fill: parent
      anchors.margins: 22
      radius: Style.cornerRadius > 0 ? 14 : 0
      color: Color.menu.background
      border.width: 1
      border.color: Color.menu.border
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.outputVisible) { root.hideOutput(); event.accepted = true }
            else if (root.searchText !== "") { searchBar.clear(); event.accepted = true }
            else if (root.selectedId !== "") { root.selectedId = ""; root.reachMode = "none"; root.updateHighlight(); event.accepted = true }
            else { root.close(); event.accepted = true }
          } else if (event.key === Qt.Key_Slash && !searchBar.hasFocus) {
            searchBar.focusField(); event.accepted = true
          } else if (event.text === "u" || event.text === "U") {
            if (root.selectedId !== "") {
              root.reachMode = root.reachMode === "up" ? "none" : "up"; root.updateHighlight(); event.accepted = true
            }
          } else if (event.text === "d" || event.text === "D") {
            if (root.selectedId !== "") {
              root.reachMode = root.reachMode === "down" ? "none" : "down"; root.updateHighlight(); event.accepted = true
            }
          } else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) {
            root.zoom = Math.min(2.0, root.zoom + 0.1); event.accepted = true
          } else if (event.key === Qt.Key_Minus) {
            root.zoom = Math.max(0.4, root.zoom - 0.1); event.accepted = true
          } else if (event.key === Qt.Key_0) {
            root.zoom = 1.0; event.accepted = true
          } else if (event.key === Qt.Key_R) {
            fullPoller.refresh(); event.accepted = true
          }
        }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 10

        // Toolbar.
        RowLayout {
          Layout.fillWidth: true
          spacing: 10
          Text {
            Layout.alignment: Qt.AlignVCenter
            text: "⎈ " + (root.context !== "" ? root.context : "kubernetes")
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Text {
            Layout.alignment: Qt.AlignVCenter
            text: root.reachInfo
            visible: root.reachInfo !== ""
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
          // Port-forward status pill: visible while connected, ✕ disconnects.
          Rectangle {
            visible: root.pfActive
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredHeight: 28
            Layout.preferredWidth: pfPillRow.implicitWidth + 20
            radius: Style.cornerRadius > 0 ? 14 : 0
            color: "#064E3B"
            border.width: 1
            border.color: Color.accent
            Row {
              id: pfPillRow
              anchors.centerIn: parent
              spacing: 8
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "⇄ " + root.pfLabel
                color: "#D1FAE5"
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "✕"
                color: "#D1FAE5"
                font.pixelSize: 12
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.stopPortForward()
                }
              }
            }
          }
          Text {
            visible: !root.pfActive && root.pfError !== ""
            Layout.alignment: Qt.AlignVCenter
            Layout.maximumWidth: 420
            text: "⚠ port-fwd: " + root.pfError.split("\n")[0]
            color: "#FB7185"
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
          SearchBar {
            id: searchBar
            Layout.preferredWidth: 260
            Layout.alignment: Qt.AlignVCenter
            keyTarget: keyCatcher
            onTextChanged: root.onSearch(text)
            onAccepted: {
              if (root.searchHits.length > 0) root.selectNode(root.searchHits[0])
            }
          }
        }

        // Filter row: namespace cycler + kind chips + zoom + refresh.
        RowLayout {
          Layout.fillWidth: true
          spacing: 8
          Rectangle {
            Layout.preferredHeight: 30
            Layout.preferredWidth: nsLabel.implicitWidth + 52
            radius: Style.cornerRadius > 0 ? 15 : 0
            color: "transparent"
            border.width: 1
            border.color: Color.accent
            Text {
              id: nsLabel
              anchors.centerIn: parent
              text: "ns: " + (root.selectedNamespace === "__all" ? "all" : root.selectedNamespace)
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.cycleNamespace(1)
            }
          }
          Repeater {
            model: [
              { key: "Ingress", label: "Ing" },
              { key: "Service", label: "Svc" },
              { key: "__workload", label: "Work" },
              { key: "ReplicaSet", label: "RS" },
              { key: "Pod", label: "Pod" },
              { key: "Node", label: "Node" }
            ]
            Rectangle {
              required property var modelData
              Layout.preferredHeight: 30
              Layout.preferredWidth: 52
              radius: Style.cornerRadius > 0 ? 15 : 0
              color: root.hiddenKinds[modelData.key] ? "transparent" : Color.accent
              opacity: root.hiddenKinds[modelData.key] ? 0.45 : 1.0
              border.width: 1
              border.color: Color.accent
              Text {
                anchors.centerIn: parent
                text: parent.modelData.label
                color: root.hiddenKinds[modelData.key] ? Color.menu.text : Color.menu.background
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleKindFilter(parent.modelData.key)
              }
            }
          }
          Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
          Text {
            Layout.alignment: Qt.AlignVCenter
            text: "−"
            color: Color.menu.text
            font.pixelSize: 18
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.zoom = Math.max(0.4, root.zoom - 0.1)
            }
          }
          Text {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 44
            text: Math.round(root.zoom * 100) + "%"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }
          Text {
            Layout.alignment: Qt.AlignVCenter
            text: "+"
            color: Color.menu.text
            font.pixelSize: 18
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.zoom = Math.min(2.0, root.zoom + 0.1)
            }
          }
          Text {
            Layout.alignment: Qt.AlignVCenter
            text: "⟳"
            color: Color.menu.text
            font.pixelSize: 16
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: fullPoller.refresh()
            }
          }
        }

        // Main area: graph + passport.
        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 12

          Flickable {
            id: graphView
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: Math.max(width, root.layoutSize.w * root.zoom)
            contentHeight: Math.max(height, root.layoutSize.h * root.zoom + 30)
            boundsBehavior: Flickable.StopAtBounds

            Item {
              id: graphContent
              width: root.layoutSize.w
              height: root.layoutSize.h + 30
              scale: root.zoom
              transformOrigin: Item.TopLeft

              // Column headers.
              Repeater {
                model: ["Ingress", "Service", "Workload", "ReplicaSet", "Pod", "Node"]
                Text {
                  required property string modelData
                  required property int index
                  x: index * (190 + 90)
                  y: 0
                  width: 190
                  text: modelData.toUpperCase()
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }
              }

              TopoEdgeCanvas {
                x: 0; y: 30
                width: root.layoutSize.w
                height: root.layoutSize.h
                edges: root.viewEdges
                positions: edgePositions()
                highlightIds: root.reachIds
                hasHighlight: root.hasHighlight
              }

              Repeater {
                model: root.viewNodes
                TopoNode {
                  required property var modelData
                  x: modelData.x
                  y: modelData.y + 30
                  nodeId: modelData.node.id
                  nodeKind: modelData.node.kind
                  nodeName: modelData.node.name
                  nodeNs: modelData.node.namespace
                  statusLevel: modelData.node.status.level
                  statusLabel: modelData.node.status.label
                  accent: root.kindAccent(modelData.node.kind)
                  fontFamily: Style.font.family
                  selected: root.selectedId === modelData.node.id
                  dimmed: root.hasHighlight && !root.reachIds[modelData.node.id]
                  onPressed: function(id) { root.selectNode(id) }
                }
              }

              // Loading / error / empty states overlay the canvas.
              Rectangle {
                visible: root.loadState !== "ready"
                anchors.centerIn: parent
                width: 420
                height: stateCol.implicitHeight + 40
                radius: 12
                color: Color.menu.background
                border.width: 1
                border.color: Color.menu.border
                Column {
                  id: stateCol
                  anchors.centerIn: parent
                  width: parent.width - 40
                  spacing: 8
                  Text {
                    width: parent.width
                    text: root.loadState === "loading" ? "Reading cluster…"
                      : root.loadState === "error" ? root.loadError : "No resources in scope"
                    color: Color.menu.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                    wrapMode: Text.Wrap
                  }
                  Text {
                    width: parent.width
                    visible: root.loadDetail !== "" && root.loadState === "error"
                    text: root.loadDetail
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.Wrap
                  }
                  Text {
                    visible: root.loadState === "error"
                    text: "Retry  (R)"
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: fullPoller.refresh()
                    }
                  }
                }
              }
            }
          }

          Passport {
            id: passport
            Layout.preferredWidth: 320
            Layout.fillHeight: true
            Layout.leftMargin: 0
            node: root.selectedNode()
            inEdges: root.relatedEdges("in")
            outEdges: root.relatedEdges("out")
            pfActive: root.pfActive
            pfKey: root.pfKey
            onRunCommand: function(cmd) { root.runInTerminal(cmd) }
            onCopyText: function(value) { root.copyToClipboard(value) }
            onShowOutput: function(title, cmdArgs, terminalCmd) {
              root.showOutput(title, cmdArgs, terminalCmd)
            }
            onTogglePortForward: root.togglePortForward()
            onClosed: { root.selectedId = ""; root.reachMode = "none"; root.updateHighlight() }
          }
        }

        // Status bar.
        RowLayout {
          id: statusBar
          Layout.fillWidth: true
          spacing: 16
          Text {
            text: root.viewNodes.length + " nodes · " + root.viewEdges.length + " edges"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            Layout.fillWidth: true
            visible: root.viewWarnings.length > 0
            text: root.viewWarnings.length > 0
              ? ("⚠ " + root.viewWarnings.length + " warning(s): " + root.viewWarnings[0].text)
              : ""
            color: "#FBBF24"
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
          Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
          Text {
            text: root.updatedAt !== "" ? ("updated " + root.updatedAt) : ""
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      // In-plugin output viewer: floats above graph + passport, shows
      // logs / describe output without leaving the overlay.
      Rectangle {
        id: outputCard
        visible: root.outputVisible
        anchors.fill: parent
        anchors.margins: 48
        radius: Style.cornerRadius > 0 ? 14 : 0
        color: Color.menu.background
        border.width: 1
        border.color: Color.menu.border

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: 16
          spacing: 10

          RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
              Layout.fillWidth: true
              text: root.outputTitle + (root.outputBusy ? "  …" : "")
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              text: "✕"
              color: Color.muted
              font.pixelSize: 14
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.hideOutput()
              }
            }
          }

          Text {
            Layout.fillWidth: true
            text: "$ " + root.outputTerminalCmd
            color: Color.muted
            font.family: "monospace"
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Flickable {
            id: outputScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: outputBodyText.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            Text {
              id: outputBodyText
              width: parent.width
              text: root.outputBusy ? "Running…" : root.outputBody
              color: Color.menu.text
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.outputCopiedMsg !== ""
            text: root.outputCopiedMsg
            color: "#34D399"
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
              model: [
                { label: "Copy output", cmd: "out" },
                { label: "Copy command", cmd: "cmd" },
                { label: "Open in terminal", cmd: "term" },
                { label: "Close", cmd: "close" }
              ]
              Rectangle {
                required property var modelData
                Layout.fillWidth: true
                Layout.preferredHeight: 32
                radius: Style.cornerRadius > 0 ? 8 : 0
                color: "transparent"
                border.width: 1
                border.color: Color.accent
                Text {
                  anchors.centerIn: parent
                  text: parent.modelData.label
                  color: Color.menu.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var c = parent.modelData.cmd
                    if (c === "out") root.copyOutputText(root.outputBody, "Output")
                    else if (c === "cmd") root.copyOutputText(root.outputTerminalCmd, "Command")
                    else if (c === "term") root.runInTerminal(root.outputTerminalCmd)
                    else if (c === "close") root.hideOutput()
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // Edge canvas works in unscaled graph coords (y offset by header).
  function edgePositions() {
    return root.viewNodes.reduce(function(acc, v) {
      acc[v.node.id] = { x: v.x, y: v.y, w: 190, h: 64 }
      return acc
    }, {})
  }
}
