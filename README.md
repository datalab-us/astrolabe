# Astrolabe K8s — Kubernetes topology for Omarchy

Bar status + fullscreen workload/network topology overlay for the Omarchy
Quattro shell. See cluster resources, how Services select Pods, what your
Ingresses route to, and trace upstream/downstream relationships — in the
visual spirit of [Archify](https://github.com/tt-a1i/archify), rendered
natively in QML.

## Install

```sh
omarchy plugin add https://github.com/datalab-us/astrolabe.git --enable
```

Requires `kubectl` and a working kubeconfig. The plugin is **read-only**:
it runs `kubectl get … -o json` and `kubectl config current-context`.
Logs / describe render inside the overlay (with Copy + Open-in-terminal
fallback via `xdg-terminal-exec`); port-forward runs managed while the
overlay is open. Nothing mutates the cluster from the shell process.

## Usage

- Bar pill shows `⎈ <context> <ready>/<total>` pods. Click to open the overlay.
- Overlay: namespace cycler (`ns: all`), kind filter chips, search (`/`),
  click a node for the detail passport, `u`/`d` for upstream/downstream
  reach, `+`/`-`/`0` zoom, `R` refresh, `Esc` back/close.
- Passport actions: Logs / Describe (shown inside the overlay, with Copy
  output, Copy command, Open in terminal), Port-fwd (managed
  `localhost:8080` → the target's service port, with a toolbar status pill
  — click ✕ to disconnect), Copy describe (copies the `kubectl describe`
  command).
- Summon with an optional namespace payload (empty payload reopens with
  the current filters):
  `omarchy-shell shell summon io.github.astrolabe.k8s-topo '{"namespace":"demo"}'`

## Configure

```sh
omarchy bar move io.github.astrolabe.k8s-topo --section right
```

## Layout

```
manifest.json      plugin contract (bar-widget + overlay)
BarWidget.qml      bar pill: context + pod readiness, toggles overlay
Overlay.qml        fullscreen topology canvas + passport
components/
  K8sPoller.qml    shared kubectl Process poller
  TopoNode.qml     node card
  TopoEdgeCanvas.qml  edge layer (owns/selects/serves/routes-to/runs-on)
  Passport.qml     selected-node detail + safe actions
  SearchBar.qml    filter field
Model.js           pure kubectl helpers (tested)
K8sGraph.js        pure topology IR: build/reach/search/layout (tested)
mock/              sample cluster bundle for offline tests
tests/             node --test suites (no cluster needed)
```

## Develop

```sh
./scripts/test                    # pure-JS tests, no cluster
omarchy plugin validate .         # manifest + layout checks
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Overlay.qml components/*.qml
```

Live iteration: symlink or copy this folder to
`~/.config/omarchy/plugins/io.github.astrolabe.k8s-topo/`, then
`omarchy-shell shell rescanPlugins`. Saving any file hot-reloads.

To try against a local cluster without credentials risk, use
[kwok](https://kwok.sigs.k8s.io/) (real API server, fake nodes — no
Docker/root needed) or k3d:

```sh
kwokctl create cluster --name astrolabe
kubectl apply -f /tmp/astrolabe-demo.yaml  # any deploy/svc/ingress manifests
```

Note: the overlay is `keepLoaded`, so after editing QML under an open
overlay, hide it first, then `omarchy-shell shell rescanPlugins` and
summon again — otherwise the pre-reload instance can linger.

## Remove

```sh
omarchy plugin remove io.github.astrolabe.k8s-topo
```

## License

ELv2 (Elastic License 2.0) — see LICENSE.
