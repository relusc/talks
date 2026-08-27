# Multi-stage build
FROM golang:1.26-alpine AS builder

WORKDIR /app

# Copy source code
COPY . .

# App build, statically linked for alpine
RUN CGO_ENABLED=0 GOOS=linux GOARCH="arm64" go build -ldflags="-s -w" -trimpath -o main .

# Alpine image
FROM scratch

# Copy binary from build stage
COPY --from=builder /app/main .

# non-root user
USER 65532:65532

# Start application
CMD ["./main"]
