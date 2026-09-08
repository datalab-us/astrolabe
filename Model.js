// Model.js — pure kubectl helpers for Astrolabe K8s.
// Runs both in QML (`import "Model.js" as Model`) and under plain Node tests.
// Keep ES5-style syntax: no template literals, no optional chaining.

// Resources fetched for the v1 topology (workloads + network + placement).
function topoResources() {
  return ["deploy", "rs", "sts", "ds", "job", "pods", "svc", "endpointslices", "ingress", "nodes"];
}

function summaryResources() {
  return ["pods"];
}

// ["kubectl","get","deploy,rs,...","-n","demo","-o","json"]
function kubectlGetArgs(resources, namespace) {
  var args = ["kubectl", "get", resources.join(","), "-o", "json"];
  if (namespace && namespace !== "__all") {
    args.push("-n", namespace);
  } else {
    args.push("-A");
  }
  return args;
}

// {ok:true,data} | {ok:false,error}
function safeParseJson(raw) {
  try {
    if (raw === null || raw === undefined || String(raw).trim() === "") {
      return { ok: false, error: "empty output" };
    }
    return { ok: true, data: JSON.parse(raw) };
  } catch (e) {
    return { ok: false, error: "invalid JSON: " + String(e && e.message || e) };
  }
}

function listItems(list) {
  if (!list) return [];
  if (Array.isArray(list)) return list;
  if (list.items && Array.isArray(list.items)) return list.items;
  return [];
}

function metaOf(obj) {
  return (obj && obj.metadata) || {};
}

function objectName(obj) {
  return metaOf(obj).name || "";
}

function objectNamespace(obj) {
  return metaOf(obj).namespace || "";
}

// Label-selector matching (matchLabels only in v1). An empty/undefined
// selector matches nothing: a selectorless Service selects no Pods.
function matchLabels(podLabels, selector) {
  if (!selector) return false;
  var keys = Object.keys(selector);
  if (keys.length === 0) return false;
  var labels = podLabels || {};
  for (var i = 0; i < keys.length; i++) {
    if (labels[keys[i]] !== selector[keys[i]]) return false;
  }
  return true;
}

function podContainerStatuses(pod) {
  var s = pod.status || {};
  var all = [];
  var lists = [s.containerStatuses, s.initContainerStatuses, s.ephemeralContainerStatuses];
  for (var i = 0; i < lists.length; i++) {
    if (Array.isArray(lists[i])) all = all.concat(lists[i]);
  }
  return all;
}

function podReadyCount(pod) {
  var all = podContainerStatuses(pod);
  var ready = 0;
  for (var i = 0; i < all.length; i++) {
    if (all[i].ready) ready++;
  }
  return { ready: ready, total: all.length };
}

function podRestarts(pod) {
  var all = podContainerStatuses(pod);
  var n = 0;
  for (var i = 0; i < all.length; i++) {
    n += Number(all[i].restartCount || 0);
  }
  return n;
}

// Worst waiting/terminated reason across containers, or "".
function podWaitingReason(pod) {
  var all = podContainerStatuses(pod);
  for (var i = 0; i < all.length; i++) {
    var st = all[i].state || {};
    if (st.waiting && st.waiting.reason) return st.waiting.reason;
    if (st.terminated && st.terminated.reason && st.terminated.exitCode !== 0) {
      return st.terminated.reason;
    }
  }
  return "";
}

var BAD_REASONS = {
  CrashLoopBackOff: true, ErrImagePull: true, ImagePullBackOff: true,
  CreateContainerConfigError: true, InvalidImageName: true, Error: true,
  Failed: true, Evicted: true, OOMKilled: true, NodeLost: true
};

// {level:"ok"|"warn"|"bad"|"unknown", label}
function podStatus(pod) {
  var phase = (pod.status && pod.status.phase) || "Unknown";
  var reason = podWaitingReason(pod);
  if (reason && BAD_REASONS[reason]) return { level: "bad", label: reason };
  if (phase === "Failed") return { level: "bad", label: "Failed" };
  if (phase === "Succeeded") return { level: "ok", label: "Succeeded" };
  if (phase === "Running") {
    var rc = podReadyCount(pod);
    if (rc.total > 0 && rc.ready < rc.total) {
      return { level: "warn", label: "NotReady " + rc.ready + "/" + rc.total };
    }
    return { level: "ok", label: "Running" };
  }
  if (phase === "Pending") {
    return { level: "warn", label: reason || "Pending" };
  }
  return { level: "unknown", label: reason || phase };
}

function nodeStatus(node) {
  var conds = (node.status && node.status.conditions) || [];
  for (var i = 0; i < conds.length; i++) {
    if (conds[i].type === "Ready") {
      return conds[i].status === "True"
        ? { level: "ok", label: "Ready" }
        : { level: "bad", label: "NotReady" };
    }
  }
  return { level: "unknown", label: "Unknown" };
}

function workloadStatus(kind, obj) {
  var s = obj.status || {};
  if (kind === "Deployment") {
    var want = obj.spec && obj.spec.replicas;
    var avail = s.availableReplicas || 0;
    if (want !== undefined && avail < want) return { level: "warn", label: avail + "/" + want };
    return { level: "ok", label: "Avail " + avail };
  }
  if (kind === "StatefulSet" || kind === "ReplicaSet") {
    var ready = s.readyReplicas || 0;
    var spec = (obj.spec && obj.spec.replicas) || 0;
    if (ready < spec) return { level: "warn", label: ready + "/" + spec };
    return { level: "ok", label: ready + "/" + spec };
  }
  if (kind === "DaemonSet") {
    var ok = s.numberReady || 0;
    var desired = s.desiredNumberScheduled || 0;
    if (ok < desired) return { level: "warn", label: ok + "/" + desired };
    return { level: "ok", label: ok + "/" + desired };
  }
  if (kind === "Job") {
    if (s.failed) return { level: "bad", label: "Failed" };
    if (s.succeeded) return { level: "ok", label: "Complete" };
    return { level: "warn", label: "Active" };
  }
  return { level: "unknown", label: kind };
}

// "2026-09-01T10:00:00Z" -> "3d", "5h", "12m". nowMs injectable for tests.
function formatAge(ts, nowMs) {
  if (!ts) return "--";
  var then = Date.parse(ts);
  if (isNaN(then)) return "--";
  var now = nowMs !== undefined ? nowMs : Date.now();
  var sec = Math.max(0, Math.floor((now - then) / 1000));
  if (sec < 60) return sec + "s";
  if (sec < 3600) return Math.floor(sec / 60) + "m";
  if (sec < 86400) return Math.floor(sec / 3600) + "h";
  return Math.floor(sec / 86400) + "d";
}

// A multi-type `kubectl get a,b,c -o json` returns one List with mixed
// items. Regroup into a K8sGraph bundle ({deployments:[...], pods:[...]}).
// Unknown kinds are ignored.
var MIXED_KIND_TO_KEY = {
  Deployment: "deployments", ReplicaSet: "replicasets", StatefulSet: "statefulsets",
  DaemonSet: "daemonsets", Job: "jobs", CronJob: "cronjobs", Pod: "pods",
  Service: "services", EndpointSlice: "endpointslices", Ingress: "ingresses",
  Node: "nodes", Namespace: "namespaces"
};

function emptyBundle() {
  return { deployments: [], replicasets: [], statefulsets: [], daemonsets: [],
    jobs: [], cronjobs: [], pods: [], services: [], endpointslices: [],
    ingresses: [], nodes: [], namespaces: [] };
}

function splitMixedList(list) {
  var bundle = emptyBundle();
  var items = listItems(list);
  for (var i = 0; i < items.length; i++) {
    var key = MIXED_KIND_TO_KEY[items[i].kind];
    if (key) bundle[key].push(items[i]);
  }
  return bundle;
}
// Bourne single-quote. Use for every interpolated kubectl argument.
function shellQuote(v) {
  return "'" + String(v).replace(/'/g, "'\\''") + "'";
}

function logsCommand(ns, pod, container) {
  var c = "kubectl logs -n " + shellQuote(ns) + " " + shellQuote(pod) + " --tail=200 -f";
  if (container) c += " -c " + shellQuote(container);
  return c;
}

function describeCommand(kind, ns, name) {
  var c = "kubectl describe " + shellQuote(kind.toLowerCase());
  if (ns) c += " -n " + shellQuote(ns);
  return c + " " + shellQuote(name);
}

function portForwardCommand(ns, target, localPort, remotePort) {
  return "kubectl port-forward -n " + shellQuote(ns) + " " + shellQuote(target) +
    " " + Number(localPort) + ":" + Number(remotePort);
}

// Array-form kubectl invocations for in-process execution (no shell, no
// quoting). Logs omit `-f` so the process terminates; the terminal fallback
// keeps following via logsCommand above.
function logsArgs(ns, pod, container) {
  var a = ["kubectl", "logs", "-n", String(ns), String(pod), "--tail=200"];
  if (container) {
    a.push("-c", String(container));
  }
  return a;
}

function describeArgs(kind, ns, name) {
  var a = ["kubectl", "describe", String(kind).toLowerCase()];
  if (ns) {
    a.push("-n", String(ns));
  }
  a.push(String(name));
  return a;
}

function portForwardArgs(ns, target, localPort, remotePort) {
  return ["kubectl", "port-forward", "-n", String(ns), String(target),
    Number(localPort) + ":" + Number(remotePort)];
}

// Render a command array as a shell string for display / copy. Words with
// only safe characters pass through; everything else is Bourne-quoted.
function argsToString(args) {
  var out = [];
  for (var i = 0; i < args.length; i++) {
    var s = String(args[i]);
    if (/^[A-Za-z0-9_:@/.\-=+,]+$/.test(s)) out.push(s);
    else out.push(shellQuote(s));
  }
  return out.join(" ");
}

// Classify a collector failure for the error-state UI.
function classifyError(exitCode, stderr, stdout) {
  var err = String(stderr || "") + "\n" + String(stdout || "");
  if (/command not found|No such file|not found/i.test(err) && /kubectl/i.test(err)) {
    return "no-kubectl";
  }
  if (/Unable to connect|refus|no such host|dial tcp|network is unreachable|timed out/i.test(err)) {
    return "unreachable";
  }
  if (/no configuration has been provided|invalid configuration|context .* does not exist|no context/i.test(err)) {
    return "no-kubeconfig";
  }
  if (/forbidden|Unauthorized|couldn't get current server API group/i.test(err)) {
    return "forbidden";
  }
  if (Number(exitCode) !== 0 && String(stdout || "").trim() === "") {
    return "failed";
  }
  return "failed";
}

if (typeof module !== "undefined") {
  module.exports = {
    topoResources: topoResources,
    summaryResources: summaryResources,
    kubectlGetArgs: kubectlGetArgs,
    safeParseJson: safeParseJson,
    listItems: listItems,
    objectName: objectName,
    objectNamespace: objectNamespace,
    matchLabels: matchLabels,
    podContainerStatuses: podContainerStatuses,
    podReadyCount: podReadyCount,
    podRestarts: podRestarts,
    podWaitingReason: podWaitingReason,
    podStatus: podStatus,
    nodeStatus: nodeStatus,
    workloadStatus: workloadStatus,
    formatAge: formatAge,
    shellQuote: shellQuote,
    logsCommand: logsCommand,
    describeCommand: describeCommand,
    portForwardCommand: portForwardCommand,
    logsArgs: logsArgs,
    describeArgs: describeArgs,
    portForwardArgs: portForwardArgs,
    argsToString: argsToString,
    classifyError: classifyError,
    splitMixedList: splitMixedList,
    emptyBundle: emptyBundle
  };
}
