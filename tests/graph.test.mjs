// Tests for K8sGraph.js (topology IR, reachability, layout).
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const require = createRequire(import.meta.url);
const G = require("../K8sGraph.js");

const dir = dirname(fileURLToPath(import.meta.url));
const bundle = JSON.parse(readFileSync(join(dir, "../mock/sample-cluster.json"), "utf8"));

describe("buildGraph", () => {
  const g = G.buildGraph(bundle);

  it("mock items carry per-item kind like real kubectl", () => {
    for (const key of Object.keys(bundle)) {
      const items = bundle[key].items || [];
      for (const it of items) {
        assert.ok(it.kind, key + " item missing kind");
      }
    }
  });

  it("round-trips through the production mixed-List path", () => {
    const Model = require("../Model.js");
    const mixed = { kind: "List", items: [].concat(
      bundle.deployments.items, bundle.replicasets.items, bundle.pods.items,
      bundle.services.items, bundle.endpointslices.items, bundle.ingresses.items) };
    const split = Model.splitMixedList(mixed);
    split.nodes = bundle.nodes.items;
    const g2 = G.buildGraph(split);
    assert.equal(g2.nodes.length, g.nodes.length);
    assert.ok(g2.edges.length >= 8);
  });

  it("creates nodes for every resource", () => {
    const kinds = {};
    for (const n of g.nodes) kinds[n.kind] = (kinds[n.kind] || 0) + 1;
    assert.equal(kinds.Deployment, 1);
    assert.equal(kinds.ReplicaSet, 1);
    assert.equal(kinds.Pod, 3);
    assert.equal(kinds.Service, 2);
    assert.equal(kinds.Ingress, 2);
    assert.equal(kinds.Node, 1);
  });

  it("links owner chain deploy -> rs -> pod", () => {
    const has = (from, to, type) => g.edges.some(
      (e) => e.from === from && e.to === to && e.type === type);
    assert.ok(has("Deployment/demo/web", "ReplicaSet/demo/web-7d4f8b", "owns"));
    assert.ok(has("ReplicaSet/demo/web-7d4f8b", "Pod/demo/web-7d4f8b-x9k2m", "owns"));
  });

  it("links service selects + slice-verified serves", () => {
    const selects = g.edges.filter((e) => e.type === "selects");
    const serves = g.edges.filter((e) => e.type === "serves");
    assert.ok(selects.some((e) => e.from === "Service/demo/web"));
    // only the ready endpoint is served
    assert.deepEqual(serves.map((e) => e.to), ["Pod/demo/web-7d4f8b-x9k2m"]);
  });

  it("links ingress routes and warns on dangling refs", () => {
    assert.ok(g.edges.some((e) => e.from === "Ingress/demo/web" &&
      e.to === "Service/demo/web" && e.type === "routes-to"));
    const texts = g.warnings.map((w) => w.text).join("\n");
    assert.ok(texts.includes("selector matches 0 pods"));
    assert.ok(texts.includes("backend service missing not found"));
  });

  it("links pods to nodes", () => {
    assert.ok(g.edges.some((e) => e.from === "Pod/demo/web-7d4f8b-x9k2m" &&
      e.to === "Node/-/node-1" && e.type === "runs-on"));
  });

  it("derives statuses incl. CrashLoopBackOff", () => {
    const byId = {};
    for (const n of g.nodes) byId[n.id] = n;
    assert.equal(byId["Pod/demo/web-7d4f8b-z4q1n"].status.level, "bad");
    assert.equal(byId["Pod/demo/web-7d4f8b-x9k2m"].status.level, "ok");
    assert.equal(byId["Pod/demo/lonely-abc"].status.level, "warn");
  });
});

describe("reach", () => {
  const g = G.buildGraph(bundle);
  it("walks downstream deploy -> pods", () => {
    const r = G.reach(g, "Deployment/demo/web", "down");
    assert.ok(r.ids.includes("Pod/demo/web-7d4f8b-x9k2m"));
    assert.ok(r.ids.includes("Pod/demo/web-7d4f8b-z4q1n"));
    assert.ok(r.maxHops >= 2);
  });
  it("walks upstream pod -> deploy and pod -> svc -> ingress", () => {
    const r = G.reach(g, "Pod/demo/web-7d4f8b-x9k2m", "up");
    assert.ok(r.ids.includes("Deployment/demo/web"));
    assert.ok(r.ids.includes("Service/demo/web"));
    assert.ok(r.ids.includes("Ingress/demo/web"));
  });
});

describe("searchNodes", () => {
  const g = G.buildGraph(bundle);
  it("finds by substring across kind/ns/name", () => {
    assert.ok(G.searchNodes(g.nodes, "web").length >= 5);
    assert.deepEqual(G.searchNodes(g.nodes, "node-1"), ["Node/-/node-1"]);
    assert.deepEqual(G.searchNodes(g.nodes, "  "), []);
  });
});

describe("layout", () => {
  const g = G.buildGraph(bundle);
  it("places kinds in column order with positions for all nodes", () => {
    const l = G.layout(g, {});
    for (const n of g.nodes) assert.ok(l.positions[n.id], n.id);
    assert.ok(l.positions["Ingress/demo/web"].x < l.positions["Service/demo/web"].x);
    assert.ok(l.positions["Service/demo/web"].x < l.positions["Deployment/demo/web"].x);
    assert.ok(l.positions["Deployment/demo/web"].x < l.positions["Pod/demo/web-7d4f8b-x9k2m"].x);
    assert.ok(l.size.w > 0 && l.size.h > 0);
  });
});

describe("summarize", () => {
  it("counts totals and pod readiness", () => {
    const s = G.summarize(G.buildGraph(bundle));
    assert.equal(s.pods, 3);
    assert.equal(s.podsReady, 1);
    assert.ok(s.bad >= 1);
  });
});

describe("containerPorts", () => {
  it("collects container ports for port-forward defaults", () => {
    const pod = { spec: { containers: [
      { name: "web", ports: [{ containerPort: 5678 }, { containerPort: 5678 }] },
      { name: "side", ports: [{ containerPort: 9090 }] }
    ], initContainers: [{ name: "init", ports: [{ containerPort: 1234 }] }] } };
    assert.deepEqual(G.containerPorts(pod), [5678, 9090, 1234]);
    assert.deepEqual(G.containerPorts({ spec: {} }), []);
    assert.deepEqual(G.containerPorts({}), []);
  });
  it("lands on pod detail nodes", () => {
    const g = G.buildGraph({ pods: [{ kind: "Pod",
      metadata: { name: "p", namespace: "demo" },
      spec: { containers: [{ name: "web", ports: [{ containerPort: 5678 }] }] },
      status: { phase: "Running" } }] });
    assert.deepEqual(g.nodes[0].detail.ports, [5678]);
  });
});
