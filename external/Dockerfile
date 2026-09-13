# syntax=docker/dockerfile:1

FROM golang:1.27-alpine AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/craftnetd ./cmd/craftnetd

FROM alpine:3.22

RUN apk add --no-cache ca-certificates \
    && addgroup -S craftnet \
    && adduser -S -G craftnet craftnet \
    && install -d -o craftnet -g craftnet /data

COPY --from=build /out/craftnetd /usr/local/bin/craftnetd

USER craftnet
WORKDIR /data

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --quiet --spider http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["craftnetd"]
CMD ["serve", "-database", "/data/craftnet.db", "-listen", "0.0.0.0:8080"]
