# Multi-stage build
FROM golang:1.24-alpine AS builder

WORKDIR /app

# Source-Code kopieren
COPY . .

# App build, statically linked for alpine
RUN CGO_ENABLED=0 GOOS=linux go build -o main .

# Alpine image
FROM alpine:latest

# Binary aus Builder-Stage kopieren
COPY --from=builder /app/main .

# Port 8080 exposieren
EXPOSE 8080

# non-root user
RUN adduser -D -s /bin/sh appuser
USER appuser

# Anwendung starten
CMD ["./main"]
