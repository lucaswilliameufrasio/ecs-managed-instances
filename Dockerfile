FROM golang:1.27.1-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /parking-api ./cmd/parking-api

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /parking-api /parking-api
EXPOSE 8080
ENTRYPOINT ["/parking-api"]
