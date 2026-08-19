// Package main implements a small HTTP server that is compiled to a
// WASI Preview 2 ("wasip2") WebAssembly component using TinyGo.
//
// The Go standard library's net/http *server* does not run directly on the
// wasip2 target, because wasip2 exposes networking through the
// `wasi:http/incoming-handler` component interface rather than raw sockets.
// The go.wasmcloud.dev/component/net/wasihttp package bridges that gap: it
// implements the wasi:http world underneath, but still lets you write
// ordinary net/http handlers (http.Handler / http.HandlerFunc) on top.
package main

//go:generate go tool wit-bindgen-go generate --world relusc:containerdays/simpleweb --out gen ./wit

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"

	"go.wasmcloud.dev/component/net/wasihttp"
)

func init() {
	// wasihttp.Handle registers a single top-level http.Handler as the WASI
	// HTTP incoming-handler. Routing itself is done the normal Go way, with
	// http.ServeMux (or any third-party router that implements http.Handler).
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleRoot)
	mux.HandleFunc("/healthz", handleHealth)
	mux.HandleFunc("/api/echo", handleEcho)
	wasihttp.Handle(mux)
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	log.Println("request received", "method", r.Method, "path", r.URL.Path)

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintf(w, "Hello from a Go webserver running as a WASI P2 (wasip2) component!\n")
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

type echoRequest struct {
	Message string `json:"message"`
}

func handleEcho(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed, use POST", http.StatusMethodNotAllowed)
		return
	}

	var req echoRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		log.Println("failed to decode body", "error", err)
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"echo": req.Message})
}

// main must exist for TinyGo's wasip2 target, even though execution is
// driven by the exported wasi:http/incoming-handler, not by main() itself.
func main() {}
