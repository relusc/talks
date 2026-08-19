# Go HTTP server compiled to a WASI Preview 2 (wasip2) component with TinyGo

## Why this isn't just `net/http` + `tinygo build -target=wasip2`

TinyGo's `wasip2` target does not implement raw BSD sockets, so Go's
standard `net/http` **server** (`http.ListenAndServe`) does not work there.
wasip2 components instead expose HTTP through the component-model interface
`wasi:http/incoming-handler`. This example uses
[`go.wasmcloud.dev/component`](https://github.com/wasmCloud/go) (the
wasmCloud Go SDK), whose `net/wasihttp` package implements that interface
for you and lets you keep writing ordinary `http.Handler` code — routing is
done the normal way, with `http.ServeMux`.

## Prerequisites

- Go >= 1.24
- [TinyGo](https://tinygo.org/getting-started/install/) >= 0.33 (wasip2 support; the SDK's README states the current minimum)
- [`wasm-tools`](https://github.com/bytecodealliance/wasm-tools) on your `PATH` — **pin the version**, don't install latest:
  ```bash
  cargo install --locked wasm-tools@1.225.0
  ```
  The wasmCloud Go SDK currently documents a working window of 1.220.0–1.225.0;
  1.226.0+ depends on unreleased `wit-bindgen-go` changes. Check the
  [SDK README](https://github.com/wasmCloud/go/tree/main/component) for the
  current window before you build.
- [`wkg`](https://github.com/bytecodealliance/wasm-pkg-tools) to fetch WIT
  dependencies (`wasi:*`, `wasmcloud:*`, ...):
  ```bash
  cargo install wkg
  ```
  (or grab a prebuilt binary from its
  [releases page](https://github.com/bytecodealliance/wasm-pkg-tools/releases)).
  Bare `wkg` only auto-resolves the `wasi` and `ba` (bytecodealliance)
  namespaces out of the box — `wasmcloud` (needed for
  `wasmcloud:component-go/imports` in `wit/world.wit`) is only known to
  `wash`. This repo ships `.wkg/config.toml` for that. Note that pointing
  `wkg` at *any* config file replaces its built-in namespace defaults
  rather than adding to them, so that file restates `wasi = "wasi.dev"`
  explicitly alongside the `wasmcloud` mapping — dropping the restatement
  would silently break `wasi:*` resolution too. If you're working inside a
  full wasmCloud project with `wash`, `wash wit fetch` / `wash build`
  handle all of this transparently and you can skip the config file
  entirely.
- A WASI 0.2 runtime to run the result, e.g.
  [`wasmtime`](https://wasmtime.dev/) >= 20 (`wasmtime serve`), or
  [`wash`](https://wasmcloud.com/docs/installation) if you want to deploy it
  as a wasmCloud component behind the HTTP server provider.

## Project layout

```
.
├── go.mod
├── main.go          # the actual HTTP handlers (plain net/http style)
├── wit/
│   ├── world.wit     # declares the "wasmcloud:hello/hello" world
│   └── deps/          # fetched WIT dependencies (created by `make wit-fetch`)
├── .wkg/
│   └── config.toml    # tells standalone wkg how to resolve the wasmcloud namespace
├── gen/               # generated Go bindings (created by `make bindgen`)
├── Makefile
├── wkg.lock           # WIT dependency lockfile (created by `make wit-fetch`) — commit this
└── build/
    └── webserver.wasm # compiled component (created by `make build`)
```

`wit/deps/` and `gen/` are generated/fetched — add them to `.gitignore`.
Commit `wkg.lock` for reproducible builds.

## Build

```bash
make wit-fetch   # fetches wasi:*/wasmcloud:* WIT deps, writes wkg.lock
make bindgen     # generates Go bindings from the WIT world into ./gen
make build       # tinygo build -target=wasip2 ...
```

or all at once: `make rebuild`.

Equivalent manual commands, if you'd rather skip `make`:

```bash
wkg wit fetch --config .wkg/config.toml
go generate ./...
tinygo build \
  -target=wasip2 \
  --wit-package ./wit \
  --wit-world wasmcloud:hello/hello \
  -o build/webserver.wasm \
  .
```

This produces `build/webserver.wasm`, a self-contained WASI 0.2 component
(not a "core" wasm module — it already embeds the component-model
metadata, so you don't need a separate `wasm-tools component new` step).

## Run it

**Option A — wasmtime**

```bash
wasmtime serve -Scli build/webserver.wasm
# serving on http://0.0.0.0:8080 by default
curl http://localhost:8080/
curl http://localhost:8080/healthz
curl -X POST -d '{"message":"hi"}' http://localhost:8080/api/echo
```

**Option B — wasmCloud (`wash`)**, useful if you want this behind the
wasmCloud HTTP server provider / for orchestrating multiple components:

```bash
wash dev
```

`wash dev` builds the component, wires it up to the built-in HTTP server
capability provider (port 8000 by default), and hot-reloads on changes.

## Extending it

- Add routes in `main.go` by adding more `mux.HandleFunc("/path", ...)` calls
  on the `http.ServeMux`, or swap in a third-party router (e.g.
  `httprouter`) — anything implementing `http.Handler` works with
  `wasihttp.Handle`.
- Outbound HTTP calls from inside the component: use `&wasihttp.Transport{}`
  as the `http.Client`'s `Transport`, instead of `http.DefaultTransport`.
  (`wasmcloud:component-go/imports` already includes `wasi:http/outgoing-handler`,
  so no WIT changes are needed for this.)
- Structured logging: `go.wasmcloud.dev/component/log/wasilog` gives you a
  `slog`-compatible logger that reports through `wasi:logging`.
- If you add other WASI interfaces (`wasi:keyvalue`, `wasi:config`, etc. —
  common in wasmCloud), add an `import` line to `wit/world.wit`, re-run
  `make wit-fetch` and `make bindgen`, then use the generated packages under
  `gen/`.

## Common pitfalls

- **"Netdev not set" / networking errors**: happens if you try to use raw
  `net/http` client/server code paths instead of `wasihttp`. On wasip2, only
  the WASI HTTP interfaces work; there's no raw socket layer to fall back on.
- **`wasm-tools` version mismatches**: `wit-bindgen-go` and TinyGo's wasip2
  support are tied to a specific `wasm-tools` window (see Prerequisites). If
  `make build` fails with WIT/codegen errors after upgrading `wasm-tools`,
  that's the first thing to check.
- **"no registry configured for namespace..."**: bare `wkg` (no `--config`)
  knows `wasi`/`ba` by default. As soon as you pass `--config` pointing at a
  custom file (needed here for the `wasmcloud` namespace), that file's
  `namespace_registries` *replaces* the built-in defaults rather than
  extending them — so every namespace in use has to be listed, `wasi`
  included (see `.wkg/config.toml`). Missing one produces exactly this
  error. Alternatively, use `wash wit fetch`, which has all of this mapped
  internally and needs no config file.
- **Old `wit-deps`/`deps.toml` instructions**: some older blog posts and even
  older Go-SDK docs reference a separate `wit-deps` (Cargo) tool and a
  `wit/deps.toml` manifest pointing at
  `github.com/wasmCloud/component-sdk-go`. That repository was archived and
  folded into `github.com/wasmCloud/go` — those URLs 404 now. `wkg wit fetch`
  (used above) replaces that whole workflow and resolves WIT dependencies
  from `wit/world.wit` directly, no manifest needed.
- **`main` looks unused**: it's required by the wasip2 target even though
  the actual entry point is the exported `incoming-handler`, driven by
  `init()` registering your routes.
