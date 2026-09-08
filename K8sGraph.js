// K8sGraph.js — typed topology IR: kubectl Lists -> {nodes, edges, warnings}.
// Self-contained (QML forbids .js->.js imports); mirrors the small helpers
// from Model.js it needs. Tested under Node: `node --test tests/`.
// Keep ES5-style syntax for the QML engine.

// Column per kind for the deterministic DAG layout.
var KIND_COLUMN = {
  Ingress: 0,
  Service: 1,
  Deployment: 2, StatefulSet: 2, DaemonSet: 2, Job: 2, CronJob: 2,
  ReplicaSet: 3,
  Pod: 4,
  Node: 5
};

var COLUMN_NAMES = ["Ingress", "Service", "Workload", "ReplicaSet", "Pod", "Node"];

function nodeId(kind, ns, name) {
  return kind + "/" + (ns || "-") + "/" + name;
}

function itemsOf(list) {
  if (!list) return [];
  if (Array.isArray(list)) return list;
  return list.items || [];
}

function metaOf(obj) { return (obj && obj.metadata) || {}; }

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

function containerStatuses(pod) {
  var s = pod.status || {};
  var all = [];
  var lists = [s.containerStatuses, s.initContainerStatuses];
  for (var i = 0; i < lists.length; i++) {
    if (Array.isArray(lists[i])) all = all.concat(lists[i]);
  }
  return all;
}

function podStatusOf(pod) {
  var phase = (pod.status && pod.status.phase) || "Unknown";
  var all = containerStatuses(pod);
  var waiting = "";
  for (var i = 0; i < all.length; i++) {
    var st = all[i].state || {};
    if (st.waiting && st.waiting.reason) waiting = st.waiting.reason;
    if (st.terminated && st.terminated.reason && st.terminated.exitCode !== 0) waiting = st.terminated.reason;
  }
  var bad = { CrashLoopBackOff: 1, ErrImagePull: 1, ImagePullBackOff: 1, Failed: 1, Evicted: 1, OOMKilled: 1 };
  if (waiting && bad[waiting]) return { level: "bad", label: waiting };
  if (phase === "Failed") return { level: "bad", label: "Failed" };
  if (phase === "Succeeded") return { level: "ok", label: "Succeeded" };
  if (phase === "Running") {
    var ready = 0;
    for (var j = 0; j < all.length; j++) { if (all[j].ready) ready++; }
    if (all.length > 0 && ready < all.length) return { level: "warn", label: "NotReady" };
    return { level: "ok", label: "Running" };
  }
  if (phase === "Pending") return { level: "warn", label: waiting || "Pending" };
  return { level: "unknown", label: waiting || phase };
}

function workloadStatusOf(kind, obj) {
  var s = obj.status || {};
  if (kind === "Deployment") {
    var want = (obj.spec && obj.spec.replicas !== undefined) ? obj.spec.replicas : 1;
    var avail = s.availableReplicas || 0;
    return avail < want ? { level: "warn", label: avail + "/" + want } : { level: "ok", label: avail + "/" + want };
  }
  if (kind === "StatefulSet" || kind === "ReplicaSet") {
    var r = s.readyReplicas || 0;
    var sp = (obj.spec && obj.spec.replicas) || 0;
    return r < sp ? { level: "warn", label: r + "/" + sp } : { level: "ok", label: r + "/" + sp };
  }
  if (kind === "DaemonSet") {
    var ok = s.numberReady || 0, des = s.desiredNumberScheduled || 0;
    return ok < des ? { level: "warn", label: ok + "/" + des } : { level: "ok", label: ok + "/" + des };
  }
  if (kind === "Job") {
    if (s.failed) return { level: "bad", label: "Failed" };
    if (s.succeeded) return { level: "ok", label: "Complete" };
    return { level: "warn", label: "Active" };
  }
  return { level: "unknown", label: kind };
}

// bundle: {deployments, replicasets, statefulsets, daemonsets, jobs,
//          pods, services, endpointslices, ingresses, nodes}
// Each value is a kubectl List object (or array). Returns:
// {nodes:[{id,kind,name,namespace,status:{level,label},detail}], edges:[{from,to,type}], warnings:[...]}
function buildGraph(bundle) {
  var b = bundle || {};
  var nodes = [];
  var edges = [];
  var warnings = [];
  var byId = {};
  var byUid = {};

  function addNode(kind, obj, status, detail) {
    var m = metaOf(obj);
    var id = nodeId(kind, m.namespace || "", m.name || "");
    if (byId[id]) return byId[id];
    var n = { id: id, kind: kind, name: m.name || "", namespace: m.namespace || "",
              status: status, detail: detail || {}, raw: obj };
    byId[id] = n;
    nodes.push(n);
    if (m.uid) byUid[m.uid] = n;
    return n;
  }

  function addEdge(from, to, type, label) {
    edges.push({ from: from, to: to, type: type, label: label || "" });
  }

  var workloads = [
    ["Deployment", itemsOf(b.deployments)],
    ["StatefulSet", itemsOf(b.statefulsets)],
    ["DaemonSet", itemsOf(b.daemonsets)],
    ["Job", itemsOf(b.jobs)],
    ["CronJob", itemsOf(b.cronjobs)]
  ];
  var wIdx = {};
  var wi, wj;
  for (wi = 0; wi < workloads.length; wi++) {
    for (wj = 0; wj < workloads[wi][1].length; wj++) {
      var w = workloads[wi][1][wj];
      var wn = addNode(workloads[wi][0], w, workloadStatusOf(workloads[wi][0], w),
        { replicas: (w.spec && w.spec.replicas), age: metaOf(w).creationTimestamp });
      wIdx[nodeId(workloads[wi][0], metaOf(w).namespace, metaOf(w).name)] = w;
    }
  }

  var rss = itemsOf(b.replicasets);
  var i;
  for (i = 0; i < rss.length; i++) {
    addNode("ReplicaSet", rss[i], workloadStatusOf("ReplicaSet", rss[i]),
      { age: metaOf(rss[i]).creationTimestamp });
  }

  var pods = itemsOf(b.pods);
  var podByNsName = {};
  for (i = 0; i < pods.length; i++) {
    var p = pods[i];
    var pm = metaOf(p);
    var restarts = 0;
    var cs = containerStatuses(p);
    for (var c = 0; c < cs.length; c++) restarts += Number(cs[c].restartCount || 0);
    var pn = addNode("Pod", p, podStatusOf(p),
      { phase: (p.status && p.status.phase) || "", restarts: restarts,
        node: (p.spec && p.spec.nodeName) || "", age: pm.creationTimestamp,
        containers: containerNames(p) });
    podByNsName[(pm.namespace || "") + "/" + (pm.name || "")] = pn;
  }

  var svcs = itemsOf(b.services);
  for (i = 0; i < svcs.length; i++) {
    var svc = svcs[i];
    var spec = svc.spec || {};
    var ports = (spec.ports || []).map(function (pt) { return String(pt.port); }).join(",");
    addNode("Service", svc, { level: "ok", label: spec.clusterIP || "svc" },
      { clusterIP: spec.clusterIP, ports: ports, svcType: spec.type || "ClusterIP" });
  }

  var ings = itemsOf(b.ingresses);
  for (i = 0; i < ings.length; i++) {
    var ing = ings[i];
    var hosts = ((ing.spec && ing.spec.rules) || []).map(function (r) { return r.host || ""; });
    addNode("Ingress", ing, { level: "ok", label: hosts.length ? hosts[0] : "ingress" },
      { hosts: hosts });
  }

  var nds = itemsOf(b.nodes);
  for (i = 0; i < nds.length; i++) {
    var nd = nds[i];
    var conds = (nd.status && nd.status.conditions) || [];
    var lvl = "unknown", lbl = "Unknown";
    for (var k = 0; k < conds.length; k++) {
      if (conds[k].type === "Ready") {
        lvl = conds[k].status === "True" ? "ok" : "bad";
        lbl = conds[k].status === "True" ? "Ready" : "NotReady";
      }
    }
    addNode("Node", nd, { level: lvl, label: lbl }, {});
  }

  // owns: ownerReferences by uid (fallback: same ns + kind + name).
  var ownedLists = [["ReplicaSet", rss], ["Pod", pods]];
  var oi;
  for (oi = 0; oi < ownedLists.length; oi++) {
    var ownedKind = ownedLists[oi][0];
    var ownedObjs = ownedLists[oi][1];
    for (i = 0; i < ownedObjs.length; i++) {
      var o = ownedObjs[i];
      var om = metaOf(o);
      var ownedNode = byId[nodeId(ownedKind, om.namespace || "", om.name || "")];
      if (!ownedNode) continue;
      var refs = om.ownerReferences || [];
      for (var r = 0; r < refs.length; r++) {
        var ref = refs[r];
        var owner = byUid[ref.uid];
        if (!owner) {
          var cand = byId[nodeId(ref.kind, om.namespace || "", ref.name)];
          if (cand) owner = cand;
        }
        if (owner) {
          addEdge(owner.id, ownedNode.id, "owns");
        } else {
          warnings.push({ type: "orphan", node: ownedNode.id,
            text: "owner " + ref.kind + "/" + ref.name + " not found" });
        }
      }
    }
  }

  // selects + serves.
  var slices = itemsOf(b.endpointslices);
  // serviceKey(ns/name) -> set of ready pod ids (from EndpointSlices).
  var servedBy = {};
  for (i = 0; i < slices.length; i++) {
    var sl = slices[i];
    var slm = metaOf(sl);
    var svcName = ((slm.labels || {})["kubernetes.io/service-name"]) || "";
    if (!svcName) continue;
    var key = (slm.namespace || "") + "/" + svcName;
    var eps = sl.endpoints || [];
    for (var e = 0; e < eps.length; e++) {
      var ready = !eps[e].conditions || eps[e].conditions.ready !== false;
      var tref = eps[e].targetRef;
      if (tref && tref.kind === "Pod") {
        var pid = nodeId("Pod", tref.namespace || slm.namespace || "", tref.name);
        // selects edge: selector intent. serves edge: slice-verified.
        if (!servedBy[key]) servedBy[key] = {};
        if (ready && byId[pid]) servedBy[key][pid] = true;
      }
    }
  }
  for (i = 0; i < svcs.length; i++) {
    var s2 = svcs[i];
    var sm = metaOf(s2);
    var sid = nodeId("Service", sm.namespace || "", sm.name || "");
    var sel = (s2.spec || {}).selector;
    var matched = 0;
    for (var pi = 0; pi < pods.length; pi++) {
      var pm2 = metaOf(pods[pi]);
      if ((pm2.namespace || "") !== (sm.namespace || "")) continue;
      if (matchLabels(pm2.labels, sel)) {
        var tid = nodeId("Pod", pm2.namespace || "", pm2.name || "");
        addEdge(sid, tid, "selects");
        matched++;
      }
    }
    if (sel && Object.keys(sel).length && matched === 0) {
      warnings.push({ type: "dangling", node: sid, text: "selector matches 0 pods" });
    }
    var sk = (sm.namespace || "") + "/" + (sm.name || "");
    var served = servedBy[sk] || {};
    var pids = Object.keys(served);
    for (var si = 0; si < pids.length; si++) {
      addEdge(sid, pids[si], "serves");
    }
  }

  // routes-to: ingress -> service.
  for (i = 0; i < ings.length; i++) {
    var ig = ings[i];
    var igm = metaOf(ig);
    var iid = nodeId("Ingress", igm.namespace || "", igm.name || "");
    var rules = (ig.spec && ig.spec.rules) || [];
    var backends = [];
    var dflt = ig.spec && ig.spec.defaultBackend;
    if (dflt && dflt.service) backends.push(dflt.service.name);
    for (var ri = 0; ri < rules.length; ri++) {
      var paths = (rules[ri].http && rules[ri].http.paths) || [];
      for (var qi = 0; qi < paths.length; qi++) {
        if (paths[qi].backend && paths[qi].backend.service) backends.push(paths[qi].backend.service.name);
      }
    }
    for (var bi = 0; bi < backends.length; bi++) {
      var tgt = byId[nodeId("Service", igm.namespace || "", backends[bi])];
      if (tgt) {
        addEdge(iid, tgt.id, "routes-to");
      } else {
        warnings.push({ type: "dangling", node: iid,
          text: "backend service " + backends[bi] + " not found" });
      }
    }
  }

  // runs-on: pod -> node.
  for (i = 0; i < pods.length; i++) {
    var p3 = pods[i];
    var nn = p3.spec && p3.spec.nodeName;
    if (!nn) continue;
    var pm3 = metaOf(p3);
    var nid = byId[nodeId("Node", "", nn)];
    var pid3 = nodeId("Pod", pm3.namespace || "", pm3.name || "");
    if (nid) addEdge(pid3, nid.id, "runs-on");
  }

  return { nodes: nodes, edges: edges, warnings: warnings };
}

function containerNames(pod) {
  var out = [];
  var lists = [pod.spec && pod.spec.containers, pod.spec && pod.spec.initContainers];
  for (var i = 0; i < lists.length; i++) {
    if (Array.isArray(lists[i])) {
      for (var j = 0; j < lists[i].length; j++) out.push(lists[i][j].name);
    }
  }
  return out;
}

// BFS reachability. dir "down" follows from->to, "up" follows to->from.
// Returns {ids:[...], links:edgeCount, maxHops}.
function reach(graph, startId, dir) {
  var adj = {};
  var i;
  for (i = 0; i < graph.edges.length; i++) {
    var e = graph.edges[i];
    var a = dir === "up" ? e.to : e.from;
    var b = dir === "up" ? e.from : e.to;
    if (!adj[a]) adj[a] = [];
    adj[a].push(b);
  }
  var seen = {};
  seen[startId] = 0;
  var queue = [startId];
  var links = 0;
  while (queue.length) {
    var cur = queue.shift();
    var next = adj[cur] || [];
    for (i = 0; i < next.length; i++) {
      if (seen[next[i]] === undefined) {
        seen[next[i]] = seen[cur] + 1;
        queue.push(next[i]);
        links++;
      }
    }
  }
  var ids = Object.keys(seen);
  var maxHops = 0;
  for (i = 0; i < ids.length; i++) {
    if (seen[ids[i]] > maxHops) maxHops = seen[ids[i]];
  }
  return { ids: ids, links: links, maxHops: maxHops };
}

// Substring search over "kind ns name".
function searchNodes(nodes, q) {
  var query = String(q || "").trim().toLowerCase();
  if (!query) return [];
  var out = [];
  for (var i = 0; i < nodes.length; i++) {
    var hay = (nodes[i].kind + " " + nodes[i].namespace + " " + nodes[i].name).toLowerCase();
    if (hay.indexOf(query) !== -1) out.push(nodes[i].id);
  }
  return out;
}

// Deterministic column layout. Returns {positions:{id:{x,y,w,h}}, size:{w,h}}.
function layout(graph, opts) {
  var o = opts || {};
  var nodeW = o.nodeW || 190;
  var nodeH = o.nodeH || 64;
  var gapX = o.gapX || 90;
  var gapY = o.gapY || 14;
  var nsGap = o.nsGap || 30;

  var cols = [[], [], [], [], [], []];
  var i;
  for (i = 0; i < graph.nodes.length; i++) {
    var n = graph.nodes[i];
    var c = KIND_COLUMN[n.kind];
    if (c === undefined) c = 2;
    cols[c].push(n);
  }
  var positions = {};
  var maxH = 0;
  for (var ci = 0; ci < cols.length; ci++) {
    cols[ci].sort(function (a, b) {
      if (a.namespace < b.namespace) return -1;
      if (a.namespace > b.namespace) return 1;
      if (a.name < b.name) return -1;
      if (a.name > b.name) return 1;
      return 0;
    });
    var y = 0;
    var lastNs = null;
    for (i = 0; i < cols[ci].length; i++) {
      var nd = cols[ci][i];
      if (lastNs !== null && nd.namespace !== lastNs) y += nsGap;
      lastNs = nd.namespace;
      positions[nd.id] = { x: ci * (nodeW + gapX), y: y, w: nodeW, h: nodeH };
      y += nodeH + gapY;
    }
    if (y > maxH) maxH = y;
  }
  var w = cols.length * nodeW + (cols.length - 1) * gapX;
  return { positions: positions, size: { w: w, h: Math.max(maxH, 100) }, columns: COLUMN_NAMES };
}

function summarize(graph) {
  var total = 0, bad = 0, warn = 0;
  var pods = 0, podsReady = 0;
  for (var i = 0; i < graph.nodes.length; i++) {
    var n = graph.nodes[i];
    total++;
    if (n.status.level === "bad") bad++;
    else if (n.status.level === "warn") warn++;
    if (n.kind === "Pod") {
      pods++;
      if (n.status.level === "ok") podsReady++;
    }
  }
  return { total: total, bad: bad, warn: warn, pods: pods, podsReady: podsReady };
}

if (typeof module !== "undefined") {
  module.exports = {
    KIND_COLUMN: KIND_COLUMN,
    COLUMN_NAMES: COLUMN_NAMES,
    nodeId: nodeId,
    buildGraph: buildGraph,
    containerNames: containerNames,
    reach: reach,
    searchNodes: searchNodes,
    layout: layout,
    summarize: summarize
  };
}
