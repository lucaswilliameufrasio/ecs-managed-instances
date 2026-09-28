package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
	var spots responseBody
	if err := json.NewDecoder(response.Body).Decode(&spots); err != nil {
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

type responseBody struct {
	Occupied  int64 `json:"occupied"`
	Capacity  int64 `json:"capacity"`
	Available int64 `json:"available"`
}
