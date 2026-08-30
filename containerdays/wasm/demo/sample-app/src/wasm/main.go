// The Go standard library's net/http server does not run directly on the
// wasip2 target, because wasip2 exposes networking through the
// `wasi:http/incoming-handler` component interface rather than raw sockets.
// The go.wasmcloud.dev/component/net/wasihttp package bridges that gap: it
// implements the wasi:http world underneath, but still lets you write
// ordinary net/http handlers (http.Handler / http.HandlerFunc) on top.
package main

import (
	"encoding/json"
	"net/http"
	"time"

	"go.wasmcloud.dev/component/net/wasihttp"
)

func init() {
	// wasihttp.Handle registers a single top-level http.Handler as the WASI
	// HTTP incoming-handler. Routing itself is done the normal Go way, with
	// http.ServeMux (or any third-party router that implements http.Handler).
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleRoot)

	wasihttp.Handle(mux)
}

type Response struct {
	Status      int
	ContentType string
	Body        []byte
}

type EchoResponseBody struct {
	Message string    `json:"message"`
	Date    time.Time `json:"date"`
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	e := EchoResponseBody{
		Message: "Hello from ContainerDays 2026 by WASM!",
		Date:    time.Now(),
	}

	eb, _ := json.Marshal(e)

	resp := Response{
		Status:      http.StatusOK,
		ContentType: "application/json",
		Body:        eb,
	}
	writeResponse(resp, w)
}

func writeResponse(r Response, w http.ResponseWriter) {
	w.Header().Set("Content-Type", r.ContentType)
	w.WriteHeader(r.Status)
	_, _ = w.Write(r.Body)
}

// main must exist for TinyGo's wasip2 target, even though execution is
// driven by the exported wasi:http/incoming-handler, not by main() itself.
func main() {}
