package main

import (
	"net/http"
	"net/url"
	"slices"
	"strings"

	"github.com/distribution/reference"
)

func (s *dockerEngine) serveEvents(w http.ResponseWriter, r *http.Request) error {
	q, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return fail(400, "invalid Docker event query")
	}
	since, err := parseDockerEventTime(q.Get("since"))
	if err != nil {
		return fail(400, err.Error())
	}
	until, err := parseDockerEventTime(q.Get("until"))
	if err != nil {
		return fail(400, err.Error())
	}
	if !until.IsZero() && until.Before(since) {
		return fail(400, "since cannot be after until")
	}
	filters, err := dockerFilters(q.Get("filters"), "type", "event", "scope", "container", "image", "label",
		"network", "volume", "daemon", "plugin", "node", "service", "secret", "config")
	if err != nil {
		return err
	}
	query := dockerEventQuery{since: since, until: until, match: func(event dockerEvent) bool {
		return matchesDockerEvent(event, filters)
	}}
	if err := s.events.serve(w, r, query); err != nil {
		return fail(503, err.Error())
	}
	return nil
}

func matchesDockerEvent(event dockerEvent, filters map[string][]string) bool {
	for field, values := range filters {
		if len(values) == 0 {
			continue
		}
		var matched bool
		switch field {
		case "type":
			matched = slices.Contains(values, event.Type)
		case "event":
			matched = matchesDockerEventAction(event.Action, values)
		case "scope":
			matched = slices.Contains(values, event.Scope)
		case "container":
			matched = slices.ContainsFunc(values, func(value string) bool {
				return strings.HasPrefix(event.Actor.ID, value) || strings.HasPrefix(event.Actor.Attributes["name"], value)
			})
		case "image":
			name := event.From
			if event.Type == "image" {
				name = event.Actor.Attributes["name"]
			}
			matched = slices.Contains(values, name) || slices.Contains(values, event.Actor.ID)
			if !matched {
				if image, err := reference.ParseNormalizedNamed(name); err == nil {
					matched = slices.Contains(values, reference.FamiliarName(image))
				}
			}
		case "label":
			matched = matchesLabels(event.Actor.Attributes, values)
		}
		if !matched {
			return false
		}
	}
	return true
}

// Call while holding s.mu so catalog transitions and event publication have
// one order. Actor attributes remain immutable after publication.
func (s *dockerEngine) containerEvent(c *dockerContainer, action string, attributes map[string]string) {
	attrs := make(map[string]string, len(c.Config.Labels)+len(attributes)+2)
	for k, v := range c.Config.Labels {
		attrs[k] = v
	}
	for k, v := range attributes {
		attrs[k] = v
	}
	attrs["name"] = c.Name
	attrs["image"] = c.Config.Image
	s.events.publish(dockerEvent{
		Type: "container", Action: action, Scope: "local",
		Actor:  dockerEventActor{ID: c.ID, Attributes: attrs},
		Status: action, ID: c.ID, From: c.Config.Image,
	})
}
