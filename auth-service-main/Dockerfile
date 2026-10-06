# Estágio 1: Build da aplicação em Go
FROM golang:1.21-alpine AS builder

WORKDIR /app

# Copia código-fonte e módulos
COPY . .

# Baixa dependências e compila binário estático
RUN go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o auth-service .

# Estágio 2: Imagem final enxuta
FROM alpine:3.19

RUN apk --no-cache add ca-certificates tzdata

WORKDIR /app

COPY --from=builder /app/auth-service /app/auth-service

EXPOSE 8001

CMD ["/app/auth-service"]
