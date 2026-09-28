// Package localguard rejects cross-site and DNS-rebinding requests to the
// unauthenticated loopback API before any handler runs.
//
// Binding to 127.0.0.1 keeps the network out but not the browser: any page
// can POST to http://127.0.0.1:45454 with a CORS-"simple" request (text/plain
// body, form post, body-less POST) that goes out without a preflight, and a
// DNS-rebinding page (evil.example → 127.0.0.1) can even read the answers.
// The same three checks as the Swift MicropodAPI (LocalRequestGuard):
//
//   - Host must be 127.0.0.1:<port>, localhost:<port> or [::1]:<port>
//     (a rebinding page always sends its own DNS name).
//   - POST — and PUT/PATCH/DELETE with a body — must carry a Connect, gRPC
//     or JSON media type; none is CORS-safelisted, so browsers must preflight.
//   - An Origin header, when present, must be on the CORS allowlist.
package localguard

import (
	"encoding/json"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
)

// HostedDocsOrigin is the API explorer's origin (mirrors CORSPolicy.swift).
const HostedDocsOrigin = "https://castlemilk.github.io"

// AllowedContentTypes are the media types a mutating request may carry.
var AllowedContentTypes = map[string]bool{
	"application/json":           true,
	"application/connect+json":   true,
	"application/proto":          true,
	"application/connect+proto":  true,
	"application/grpc":           true,
	"application/grpc+proto":     true,
	"application/grpc+json":      true,
	"application/grpc-web":       true,
	"application/grpc-web+proto": true,
	"application/grpc-web+json":  true,
}

// AllowedHost reports whether host names the loopback listener on port.
func AllowedHost(host string, port int) bool {
	h, p, err := net.SplitHostPort(strings.ToLower(strings.TrimSpace(host)))
	if err != nil {
		return false
	}
	if n, err := strconv.Atoi(p); err != nil || n != port {
		return false
	}
	return h == "127.0.0.1" || h == "localhost" || h == "::1"
}

// AllowedContentType reports whether contentType (parameters ignored) is on
// the allowlist.
func AllowedContentType(contentType string) bool {
	if contentType == "" {
		return false
	}
	mt, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		return false
	}
	return AllowedContentTypes[strings.ToLower(mt)]
}

// AllowedOrigin mirrors CORSPolicy.allowedOrigin: MICROPOD_API_CORS_ORIGINS
// (comma list, "*" accepted deliberately) or the hosted docs, plus any
// localhost / 127.0.0.1 / [::1] origin.
func AllowedOrigin(origin string) bool {
	configured := []string{HostedDocsOrigin}
	if raw := os.Getenv("MICROPOD_API_CORS_ORIGINS"); raw != "" {
		configured = nil
		for _, o := range strings.Split(raw, ",") {
			configured = append(configured, strings.TrimSpace(o))
		}
	}
	for _, allowed := range configured {
		if allowed == "*" || strings.EqualFold(allowed, origin) {
			return true
		}
	}
	u, err := url.Parse(origin)
	if err != nil {
		return false
	}
	h := u.Hostname()
	return h == "localhost" || h == "127.0.0.1" || h == "::1"
}

// Check returns 0 when r may proceed, else the HTTP status and reason.
func Check(r *http.Request, port int) (int, string) {
	if !AllowedHost(r.Host, port) {
		return http.StatusForbidden, "forbidden: Host must be 127.0.0.1:" + strconv.Itoa(port) +
			", localhost:" + strconv.Itoa(port) + " or [::1]:" + strconv.Itoa(port)
	}
	if origin := r.Header.Get("Origin"); origin != "" && !AllowedOrigin(origin) {
		return http.StatusForbidden, "forbidden: origin " + origin + " is not allowed"
	}
	hasBody := r.ContentLength > 0 || len(r.TransferEncoding) > 0
	needsType := r.Method == http.MethodPost ||
		((r.Method == http.MethodPut || r.Method == http.MethodPatch || r.Method == http.MethodDelete) && hasBody)
	if needsType && !AllowedContentType(r.Header.Get("Content-Type")) {
		return http.StatusUnsupportedMediaType,
			"unsupported media type: use application/json, application/connect+json, application/proto or application/grpc"
	}
	return 0, ""
}

// Wrap guards next for a listener on port.
func Wrap(next http.Handler, port int) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if status, reason := Check(r, port); status != 0 {
			code := "permission_denied"
			if status == http.StatusUnsupportedMediaType {
				code = "invalid_argument"
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			_ = json.NewEncoder(w).Encode(map[string]string{"code": code, "message": reason})
			return
		}
		next.ServeHTTP(w, r)
	})
}
