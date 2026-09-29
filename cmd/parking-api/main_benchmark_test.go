package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

type benchmarkResponseWriter struct {
	header http.Header
	status int
}

func newBenchmarkResponseWriter() *benchmarkResponseWriter {
	return &benchmarkResponseWriter{header: make(http.Header)}
}

func (w *benchmarkResponseWriter) Header() http.Header { return w.header }

func (w *benchmarkResponseWriter) WriteHeader(status int) { w.status = status }

func (w *benchmarkResponseWriter) Write(body []byte) (int, error) { return len(body), nil }

func (w *benchmarkResponseWriter) reset() {
	w.status = 0
	for key := range w.header {
		delete(w.header, key)
	}
}

func BenchmarkHandler(b *testing.B) {
	benchmarks := []struct {
		name     string
		requests []struct {
			method string
			path   string
		}
	}{
		{
			name: "health",
			requests: []struct {
				method string
				path   string
			}{{method: http.MethodGet, path: "/health"}},
		},
		{
			name: "spots",
			requests: []struct {
				method string
				path   string
			}{{method: http.MethodGet, path: "/spots"}},
		},
		{
			name: "park_leave_pair",
			requests: []struct {
				method string
				path   string
			}{
				{method: http.MethodPost, path: "/park"},
				{method: http.MethodPost, path: "/leave"},
			},
		},
	}

	for _, benchmark := range benchmarks {
		b.Run(benchmark.name, func(b *testing.B) {
			for _, parallel := range []bool{false, true} {
				mode := "serial"
				if parallel {
					mode = "parallel"
				}
				b.Run(mode, func(b *testing.B) {
					occupied.Store(0)
					b.Cleanup(func() { occupied.Store(0) })

					app := handler()
					requests := make([]*http.Request, len(benchmark.requests))
					for i, request := range benchmark.requests {
						requests[i] = httptest.NewRequest(request.method, request.path, nil)
					}

					b.ReportAllocs()
					b.ResetTimer()
					if parallel {
						b.RunParallel(func(pb *testing.PB) {
							writer := newBenchmarkResponseWriter()
							for pb.Next() {
								for _, request := range requests {
									writer.reset()
									app.ServeHTTP(writer, request)
								}
							}
						})
					} else {
						writer := newBenchmarkResponseWriter()
						for i := 0; i < b.N; i++ {
							for _, request := range requests {
								writer.reset()
								app.ServeHTTP(writer, request)
							}
						}
					}
					b.ReportMetric(float64(len(requests)), "requests/op")
				})
			}
		})
	}
}
