package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func TestParkingLifecycle(t *testing.T) {
	occupied.Store(0)
	t.Cleanup(func() { occupied.Store(0) })
	server := httptest.NewServer(handler())
	defer server.Close()

	request, err := http.NewRequest(http.MethodPost, server.URL+"/park", nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusCreated {
		t.Fatalf("POST /park status = %d, want %d", response.StatusCode, http.StatusCreated)
	}
	if err := response.Body.Close(); err != nil {
		t.Errorf("close /park response body: %v", err)
	}

	response, err = http.Get(server.URL + "/spots")
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := response.Body.Close(); err != nil {
			t.Errorf("close /spots response body: %v", err)
		}
	}()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	wantJSON := "{\"occupied\":1,\"capacity\":1000,\"available\":999}\n"
	if string(body) != wantJSON {
		t.Fatalf("GET /spots body = %q, want %q", body, wantJSON)
	}
	var spots responseBody
	if err := json.Unmarshal(body, &spots); err != nil {
		t.Fatal(err)
	}
	if spots.Occupied != 1 || spots.Available != capacity-1 {
		t.Fatalf("GET /spots = %+v, want occupied=1 available=%d", spots, capacity-1)
	}

	request, err = http.NewRequest(http.MethodPost, server.URL+"/leave", nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("POST /leave status = %d, want %d", response.StatusCode, http.StatusOK)
	}
	if err := response.Body.Close(); err != nil {
		t.Errorf("close /leave response body: %v", err)
	}
}

func TestParkingBounds(t *testing.T) {
	t.Run("full", func(t *testing.T) {
		occupied.Store(capacity)
		t.Cleanup(func() { occupied.Store(0) })
		response := httptest.NewRecorder()
		handler().ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/park", nil))
		if response.Code != http.StatusConflict {
			t.Fatalf("POST /park status = %d, want %d", response.Code, http.StatusConflict)
		}
	})
	t.Run("empty", func(t *testing.T) {
		occupied.Store(0)
		response := httptest.NewRecorder()
		handler().ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/leave", nil))
		if response.Code != http.StatusConflict {
			t.Fatalf("POST /leave status = %d, want %d", response.Code, http.StatusConflict)
		}
	})
}

func TestPprofIsSeparateFromApplicationHandler(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/debug/pprof/", nil)

	applicationResponse := httptest.NewRecorder()
	handler().ServeHTTP(applicationResponse, request)
	if applicationResponse.Code != http.StatusNotFound {
		t.Fatalf("application pprof route status = %d, want %d", applicationResponse.Code, http.StatusNotFound)
	}

	profileResponse := httptest.NewRecorder()
	pprofHandler().ServeHTTP(profileResponse, request)
	if profileResponse.Code != http.StatusOK {
		t.Fatalf("opt-in pprof route status = %d, want %d", profileResponse.Code, http.StatusOK)
	}
}

func TestConcurrentParkingBounds(t *testing.T) {
	t.Run("concurrent parks stop at capacity", func(t *testing.T) {
		occupied.Store(0)
		t.Cleanup(func() { occupied.Store(0) })

		statuses := runParallelRequests(handler(), int(2*capacity), http.MethodPost, "/park")
		created, full := countStatus(statuses, http.StatusCreated), countStatus(statuses, http.StatusConflict)
		if created != int(capacity) || full != int(capacity) {
			t.Fatalf("POST /park returned %d created and %d full; want %d each", created, full, capacity)
		}
		if got := occupied.Load(); got != capacity {
			t.Fatalf("occupied = %d after concurrent parking; want %d", got, capacity)
		}
	})

	t.Run("concurrent departures stop at zero", func(t *testing.T) {
		occupied.Store(capacity)
		t.Cleanup(func() { occupied.Store(0) })

		statuses := runParallelRequests(handler(), int(2*capacity), http.MethodPost, "/leave")
		left, empty := countStatus(statuses, http.StatusOK), countStatus(statuses, http.StatusConflict)
		if left != int(capacity) || empty != int(capacity) {
			t.Fatalf("POST /leave returned %d departures and %d empty; want %d each", left, empty, capacity)
		}
		if got := occupied.Load(); got != 0 {
			t.Fatalf("occupied = %d after concurrent departures; want 0", got)
		}
	})
}

func runParallelRequests(handler http.Handler, count int, method, path string) []int {
	statuses := make([]int, count)
	var workers sync.WaitGroup
	workers.Add(count)
	for i := range count {
		go func() {
			defer workers.Done()
			result := httptest.NewRecorder()
			handler.ServeHTTP(result, httptest.NewRequest(method, path, nil))
			statuses[i] = result.Code
		}()
	}
	workers.Wait()
	return statuses
}

func countStatus(statuses []int, wanted int) int {
	count := 0
	for _, status := range statuses {
		if status == wanted {
			count++
		}
	}
	return count
}

type responseBody struct {
	Occupied  int64 `json:"occupied"`
	Capacity  int64 `json:"capacity"`
	Available int64 `json:"available"`
}
