# Multi-stage build
FROM golang:1.26-alpine AS builder

WORKDIR /app

# Copy source code
COPY . .

# App build, statically linked for alpine
RUN CGO_ENABLED=0 GOOS=linux GOARCH="arm64" go build -o main .

# Alpine image
FROM alpine:latest

# Copy binary from build stage
COPY --from=builder /app/main .

# non-root user
RUN adduser -D -s /bin/sh appuser
USER appuser

# Start application
CMD ["./main"]
