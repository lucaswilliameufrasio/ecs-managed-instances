package main

import (
	"encoding/json"
	"log"
	"net/http"
	"net/http/pprof"
	"os"
	"runtime"
	"sync/atomic"
)

const capacity int64 = 1000

var occupied atomic.Int64

type response struct {
	Occupied  int64 `json:"occupied"`
	Capacity  int64 `json:"capacity"`
	Available int64 `json:"available"`
}

func main() {
	if os.Getenv("ENABLE_PPROF") == "1" {
		runtime.SetMutexProfileFraction(1)
		runtime.SetBlockProfileRate(1)
		go func() {
			address := getenv("PPROF_ADDRESS", "127.0.0.1:"+getenv("PPROF_PORT", "6060"))
			log.Printf("local-only pprof listener enabled on %s", address)
			if err := http.ListenAndServe(address, pprofHandler()); err != nil {
				log.Printf("pprof listener stopped: %v", err)
			}
		}()
	}

	address := getenv("LISTEN_ADDRESS", ":"+getenv("PORT", "8080"))
	log.Printf("parking API listening on %s", address)
	log.Fatal(http.ListenAndServe(address, handler()))
}

func pprofHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /debug/pprof/", pprof.Index)
	mux.HandleFunc("GET /debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("GET /debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("GET /debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("GET /debug/pprof/trace", pprof.Trace)
	for _, profile := range []string{"allocs", "block", "goroutine", "heap", "mutex", "threadcreate"} {
		mux.Handle("GET /debug/pprof/"+profile, pprof.Handler(profile))
	}
	return mux
}

func handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /spots", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, current())
	})
	mux.HandleFunc("POST /park", func(w http.ResponseWriter, _ *http.Request) {
		for {
			old := occupied.Load()
			if old >= capacity {
				writeJSON(w, http.StatusConflict, map[string]string{"error": "parking full"})
				return
			}
			if occupied.CompareAndSwap(old, old+1) {
				writeJSON(w, http.StatusCreated, current())
				return
			}
		}
	})
	mux.HandleFunc("POST /leave", func(w http.ResponseWriter, _ *http.Request) {
		for {
			old := occupied.Load()
			if old == 0 {
				writeJSON(w, http.StatusConflict, map[string]string{"error": "parking empty"})
				return
			}
			if occupied.CompareAndSwap(old, old-1) {
				writeJSON(w, http.StatusOK, current())
				return
			}
		}
	})

	return mux
}

func current() response {
	count := occupied.Load()
	return response{Occupied: count, Capacity: capacity, Available: capacity - count}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("encode response: %v", err)
	}
}

func getenv(key, fallback string) string {
	// Kept tiny so the API has no third-party dependencies.
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
