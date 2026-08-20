package main

import (
	"encoding/json"
	"log"
	"net/http"
	"time"
)

type Response struct {
	Status      int
	ContentType string
	Body        []byte
}

type EchoResponseBody struct {
	Message string    `json:"message"`
	Date    time.Time `json:"date"`
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleRoot)
	mux.HandleFunc("/healthz", handleHealth)

	log.Println("listening on :8080")

	if err := http.ListenAndServe(":8080", mux); err != nil {
		log.Fatal(err)
	}
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	e := EchoResponseBody{
		Message: "Hello from ContainerDays 2026 by Container!",
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

func handleHealth(w http.ResponseWriter, r *http.Request) {
	resp := Response{
		Status:      http.StatusOK,
		ContentType: "text/plain",
		Body:        []byte("OK\n"),
	}
	writeResponse(resp, w)
}

func writeResponse(r Response, w http.ResponseWriter) {
	w.Header().Set("Content-Type", r.ContentType)
	w.WriteHeader(r.Status)
	_, _ = w.Write(r.Body)
}
