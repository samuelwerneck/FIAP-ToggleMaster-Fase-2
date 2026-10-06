# Estágio 1: Build da aplicação em Go
FROM golang:1.21-alpine AS builder

WORKDIR /app

COPY . .

RUN go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o evaluation-service .

# Estágio 2: Imagem final enxuta
FROM alpine:3.19

RUN apk --no-cache add ca-certificates tzdata

WORKDIR /app

COPY --from=builder /app/evaluation-service /app/evaluation-service

EXPOSE 8004

CMD ["/app/evaluation-service"]
