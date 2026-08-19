package main

import (
	"log"
	"net/http"
)

type Response struct {
	Status      uint16
	ContentType string
	Body        []byte
}

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		result := handle(r.URL.Path)

		w.Header().Set("Content-Type", result.ContentType)
		w.WriteHeader(int(result.Status))

		_, _ = w.Write(result.Body)
	})

	log.Println("listening on :8080")

	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatal(err)
	}
}

func handle(path string) Response {
	switch path {
	case "/":
		return Response{
			Status:      200,
			ContentType: "text/plain",
			Body:        []byte("Hello from Go!\n"),
		}

	case "/healthz":
		return Response{
			Status:      200,
			ContentType: "text/plain",
			Body:        []byte("ok\n"),
		}

	default:
		return Response{
			Status:      404,
			ContentType: "text/plain",
			Body:        []byte("not found\n"),
		}
	}
}
