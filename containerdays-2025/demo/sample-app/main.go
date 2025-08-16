package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

// Main function
func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/", podNameHandler)

	http.HandleFunc("/health", healthHandler)

	log.Fatal(http.ListenAndServe(":"+port, nil))
}

// Handler function
func podNameHandler(w http.ResponseWriter, r *http.Request) {
	podName := os.Getenv("HOSTNAME")
	if podName == "" {
		podName = "unknown-pod"
	}

	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, "Pod name: %s\n", podName)

	log.Printf("Request from %s - Pod Name: %s", r.RemoteAddr, podName)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "OK")
}
