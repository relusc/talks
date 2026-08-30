# Scratch image
FROM scratch

# Copy built binary
COPY main /main

# non-root user
USER 65532:65532

# Start application
CMD ["./main"]
