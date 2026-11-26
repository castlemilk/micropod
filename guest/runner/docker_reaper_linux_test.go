package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestDockerCleanupAPIListsOnlyMatchingSessionNetworks(t *testing.T) {
	const session = "testcontainers-session-owned"
	now := time.Date(2026, 11, 26, 0, 0, 0, 0, time.UTC)
	network := func(name, digit, sid, reap, purpose string) *workerNetwork {
		return &workerNetwork{Name: name, ID: strings.Repeat(digit, 64), Driver: "bridge", Created: now,
			Labels: map[string]string{tcSession: sid, tcReap: reap, "purpose": purpose}}
	}
	active := network("active", "1", session, "true", "project")
	filtered := network("other-purpose", "2", session, "true", "other")
	foreign := network("other-session", "3", "an-independent-session", "true", "project")
	unmarked := network("retained", "4", session, "false", "project")
	engine := &dockerEngine{namedNetworks: map[string]*workerNetwork{
		active.ID: active, filtered.ID: filtered, foreign.ID: foreign, unmarked.ID: unmarked,
	}, containers: map[string]*dockerContainer{
		"fixture": {dockerRecord: dockerRecord{ID: "fixture", Name: "fixture", Phase: "running", Config: dockerConfig{
			Labels: active.Labels,
		}}},
	}}
	api := &cleanupAPI{engine: engine, session: session}
	for _, tc := range []struct {
		name, filter string
		want         int
	}{
		{"active session and caller filter", `{"label":{"purpose=project":true}}`, http.StatusOK},
		{"unknown caller filter", `{"name":{"active":true}}`, http.StatusBadRequest},
	} {
		t.Run(tc.name, func(t *testing.T) {
			query := url.Values{"filters": {tc.filter}}
			w := httptest.NewRecorder()
			api.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/networks?"+query.Encode(), nil))
			if w.Code != tc.want {
				t.Fatalf("reaper network list = %d %s, want %d", w.Code, w.Body, tc.want)
			}
			if tc.want == http.StatusOK {
				var rows []struct {
					ID           string `json:"Id"`
					Name, Driver string
					Created      time.Time
				}
				if json.Unmarshal(w.Body.Bytes(), &rows) != nil || len(rows) != 1 ||
					rows[0].ID != active.ID || rows[0].Name != active.Name || rows[0].Driver != active.Driver || !rows[0].Created.Equal(now) {
					t.Fatalf("reaper received resources outside its requested network scope: %s", w.Body)
				}
			}
		})
	}
	for _, ref := range []string{active.Name, foreign.ID, unmarked.ID} {
		w := httptest.NewRecorder()
		api.ServeHTTP(w, httptest.NewRequest(http.MethodDelete, "/v1.47/networks/"+ref, nil))
		if w.Code != http.StatusNotFound || active.deleting || foreign.deleting || unmarked.deleting {
			t.Fatalf("network %s escaped scope or activated deletion: %d %s", ref, w.Code, w.Body)
		}
	}
}
