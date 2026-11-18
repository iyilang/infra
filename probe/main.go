package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
)

const immutable = "public, max-age=31536000, immutable, s-maxage=31536000"

var (
	requests atomic.Uint64
	bootID   string
	service  = os.Getenv("K_SERVICE")
	zeroes   = make([]byte, 64*1024)
)

func main() {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		log.Fatal(err)
	}
	bootID = hex.EncodeToString(id[:])
	if service == "" {
		service = "local"
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	http.HandleFunc("/", handle)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func handle(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, "/public"), "/internal")
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("X-Probe-Instance", bootID)
	w.Header().Set("X-Probe-Service", service)
	w.Header().Set("X-Robots-Tag", "noindex, nofollow")
	if path == "/_probe/count" {
		w.Header().Set("Cache-Control", "no-store, private")
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"count": requests.Load(), "instance": bootID, "service": service,
			"public_base_url": os.Getenv("PUBLIC_BASE_URL"),
		})
		return
	}
	if path == "/_probe/health" {
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write([]byte("ok\n"))
		return
	}
	if strings.HasPrefix(path, "/_probe/body/") {
		size, err := strconv.Atoi(strings.TrimPrefix(path, "/_probe/body/"))
		if err != nil || (size != 1 && size != 10 && size != 32 && size != 64 && size != 256) {
			http.Error(w, "unsupported size", http.StatusBadRequest)
			return
		}
		requests.Add(1)
		w.Header().Set("Cache-Control", immutable)
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		// A flush before the body requests streamed rather than buffered output.
		w.WriteHeader(http.StatusOK)
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		remaining := int64(size) * 1024 * 1024
		for remaining > 0 {
			n := int64(len(zeroes))
			if remaining < n {
				n = remaining
			}
			if _, err := w.Write(zeroes[:int(n)]); err != nil {
				return
			}
			remaining -= n
		}
		return
	}
	if path == "/_probe/missing" || path == "/_probe/missing-cacheable" {
		requests.Add(1)
		if path == "/_probe/missing-cacheable" {
			w.Header().Set("Cache-Control", immutable)
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusNotFound)
		_, _ = fmt.Fprint(w, "missing\n")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	http.NotFound(w, r)
}
