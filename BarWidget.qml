import QtQuick
import Quickshell
import qs.Ui
import "components"
import "Model.js" as Model
import "K8sGraph.js" as K8sGraph

// Bar pill: current context + pod readiness. Click toggles the fullscreen
// topology overlay via the shell (`omarchy.menu` precedent).
BarWidget {
  id: root
  moduleName: "io.github.astrolabe.k8s-topo"

  property string context: ""
  property int podsTotal: 0
  property int podsReady: 0
  property int podsBad: 0
  property string probeError: "" // "" | no-kubectl | no-kubeconfig | unreachable | ...

  readonly property string labelText: {
    if (root.probeError === "no-kubectl") return "k8s: no kubectl"
    if (root.probeError !== "") return "k8s: offline"
    if (root.context === "") return "k8s: …"
    return "⎈ " + root.context + " " + root.podsReady + "/" + root.podsTotal
  }

  function toggleOverlay() {
    if (!root.bar) return
    root.bar.run("omarchy-shell shell toggle " + root.moduleName + " '{}'")
  }

  function updateContext(text, exitCode, err) {
    if (exitCode !== 0) {
      root.probeError = Model.classifyError(exitCode, err, text)
      return
    }
    root.context = String(text || "").trim()
    if (root.probeError === "no-kubeconfig" || root.probeError === "failed") root.probeError = ""
  }

  function updatePods(text, exitCode, err) {
    var parsed = Model.safeParseJson(text)
    if (exitCode !== 0 || !parsed.ok) {
      if (exitCode !== 0) root.probeError = Model.classifyError(exitCode, err, text)
      return
    }
    var g = K8sGraph.buildGraph({ pods: parsed.data })
    var s = K8sGraph.summarize(g)
    root.podsTotal = s.pods
    root.podsReady = s.podsReady
    root.podsBad = s.bad
    if (root.probeError === "failed" || root.probeError === "unreachable") root.probeError = ""
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  K8sPoller {
    id: ctxPoller
    command: ["kubectl", "config", "current-context"]
    interval: 60000
    active: true
    onFinished: function(text, code, err) { root.updateContext(text, code, err) }
  }

  K8sPoller {
    id: podsPoller
    command: ["kubectl", "get", "pods", "-A", "-o", "json"]
    interval: 60000
    active: true
    onFinished: function(text, code, err) { root.updatePods(text, code, err) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    tooltipText: root.podsBad > 0
      ? (root.podsBad + " pod(s) unhealthy — open topology")
      : "Open Kubernetes topology"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggleOverlay()
    }
  }
}
