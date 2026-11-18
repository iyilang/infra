FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o /probe .

FROM scratch
COPY --from=build /probe /probe
USER 65532:65532
ENTRYPOINT ["/probe"]
