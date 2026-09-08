// Tests for Model.js (pure kubectl helpers).
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const Model = require("../Model.js");

describe("kubectlGetArgs", () => {
  it("scopes to a namespace", () => {
    assert.deepEqual(Model.kubectlGetArgs(["pods"], "demo"),
      ["kubectl", "get", "pods", "-o", "json", "-n", "demo"]);
  });
  it("uses -A for __all", () => {
    assert.ok(Model.kubectlGetArgs(["pods"], "__all").includes("-A"));
  });
});

describe("safeParseJson", () => {
  it("parses valid JSON", () => {
    const r = Model.safeParseJson('{"a":1}');
    assert.equal(r.ok, true);
    assert.equal(r.data.a, 1);
  });
  it("rejects garbage and empty", () => {
    assert.equal(Model.safeParseJson("nope").ok, false);
    assert.equal(Model.safeParseJson("").ok, false);
  });
});

describe("matchLabels", () => {
  it("matches subsets, rejects mismatches and empty selectors", () => {
    assert.equal(Model.matchLabels({ app: "web", v: "1" }, { app: "web" }), true);
    assert.equal(Model.matchLabels({ app: "api" }, { app: "web" }), false);
    assert.equal(Model.matchLabels({ app: "web" }, {}), false);
    assert.equal(Model.matchLabels({ app: "web" }, undefined), false);
  });
});

describe("podStatus", () => {
  it("flags CrashLoopBackOff as bad", () => {
    const pod = { status: { phase: "Running", containerStatuses: [
      { ready: false, restartCount: 5, state: { waiting: { reason: "CrashLoopBackOff" } } }
    ] } };
    assert.deepEqual(Model.podStatus(pod), { level: "bad", label: "CrashLoopBackOff" });
  });
  it("marks healthy running pods ok", () => {
    const pod = { status: { phase: "Running", containerStatuses: [
      { ready: true, restartCount: 0, state: { running: {} } }
    ] } };
    assert.equal(Model.podStatus(pod).level, "ok");
  });
  it("marks partially-ready pods warn", () => {
    const pod = { status: { phase: "Running", containerStatuses: [
      { ready: true, state: {} }, { ready: false, state: {} }
    ] } };
    assert.equal(Model.podStatus(pod).level, "warn");
  });
});

describe("formatAge", () => {
  it("formats durations", () => {
    const now = Date.parse("2026-09-07T12:00:00Z");
    assert.equal(Model.formatAge("2026-09-07T11:59:30Z", now), "30s");
    assert.equal(Model.formatAge("2026-09-07T11:00:00Z", now), "1h");
    assert.equal(Model.formatAge("2026-09-04T12:00:00Z", now), "3d");
    assert.equal(Model.formatAge("", now), "--");
  });
});

describe("shellQuote", () => {
  it("quotes spaces and single quotes", () => {
    assert.equal(Model.shellQuote("a b"), "'a b'");
    assert.equal(Model.shellQuote("o'clock"), "'o'\\''clock'");
  });
});

describe("commands", () => {
  it("builds logs/describe/port-forward", () => {
    assert.ok(Model.logsCommand("demo", "web-x", "web").includes("kubectl logs"));
    assert.ok(Model.describeCommand("Pod", "demo", "web-x").includes("kubectl describe"));
    assert.ok(Model.portForwardCommand("demo", "svc/web", 8080, 80).includes("8080:80"));
  });
});

describe("splitMixedList", () => {
  it("regroups mixed-type Lists into a bundle", () => {
    const b = Model.splitMixedList({ items: [
      { kind: "Pod", metadata: { name: "a" } },
      { kind: "Service", metadata: { name: "b" } },
      { kind: "Weird", metadata: { name: "c" } }
    ] });
    assert.equal(b.pods.length, 1);
    assert.equal(b.services.length, 1);
    assert.equal(b.deployments.length, 0);
  });
});

describe("classifyError", () => {
  it("detects missing kubectl and unreachable clusters", () => {
    assert.equal(Model.classifyError(127, "kubectl: command not found", ""), "no-kubectl");
    assert.equal(Model.classifyError(1, "Unable to connect to the server: dial tcp", ""), "unreachable");
    assert.equal(Model.classifyError(1, "The connection to the server 127.0.0.1:32764 was refused", ""), "unreachable");
    assert.equal(Model.classifyError(1, "error: no configuration has been provided", ""), "no-kubeconfig");
  });
});
