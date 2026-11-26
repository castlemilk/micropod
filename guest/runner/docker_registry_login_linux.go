package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	registryauth "github.com/containerd/containerd/remotes/docker/auth"
	remoteserrors "github.com/containerd/containerd/remotes/errors"
	"github.com/distribution/reference"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type dockerRegistryAuth struct {
	Username, Password, Auth, ServerAddress, IdentityToken, RegistryToken string
}

func registryPullCredentials(w http.ResponseWriter, r *http.Request, ref string) (*cri.AuthConfig, error) {
	if len(r.Header.Values("X-Registry-Auth")) == 0 {
		return nil, nil
	}
	name, err := reference.ParseNormalizedNamed(ref)
	if err != nil {
		return nil, fail(400, "invalid pull reference")
	}
	host := reference.Domain(name)
	auth, err := imageRegistryCredentials(w, r, host)
	if err != nil {
		return nil, err
	}
	if auth.RegistryToken != "" {
		return nil, fail(501, "direct registry token authentication is unavailable")
	}
	if auth.IdentityToken == "" && auth.Username == "" {
		return nil, nil
	}
	// CRI compares the resolver's host with URL.Host. It requires a scheme
	// even when the Docker client's ServerAddress is a bare host:port.
	return &cri.AuthConfig{Username: auth.Username, Password: auth.Password, IdentityToken: auth.IdentityToken,
		ServerAddress: "https://" + pushRegistryHost(host)}, nil
}

func registryLogin(w http.ResponseWriter, r *http.Request) error {
	body, err := readBody(w, r)
	if err != nil {
		return err
	}
	var config *dockerRegistryAuth
	if json.Unmarshal(body, &config) != nil || config == nil {
		return fail(400, "invalid registry authentication")
	}
	if config.Auth != "" && config.Username == "" && config.Password == "" {
		b, err := base64.StdEncoding.DecodeString(config.Auth)
		username, password, ok := strings.Cut(string(b), ":")
		if err != nil || !ok {
			return fail(400, "invalid registry authentication")
		}
		config.Username, config.Password = username, password
	}
	endpoint, err := registryLoginEndpoint(config.ServerAddress)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	token, err := verifyRegistryLogin(ctx, http.DefaultTransport, endpoint, config)
	if err != nil {
		return err
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, 200, struct {
		Status        string
		IdentityToken string `json:",omitempty"`
	}{"Login Succeeded", token})
	return nil
}

func registryLoginEndpoint(address string) (*url.URL, error) {
	if address == "" {
		address = "registry-1.docker.io"
	}
	if !strings.Contains(address, "://") {
		address = "https://" + address
	}
	u, err := url.Parse(address)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" ||
		u.ForceQuery || u.Fragment != "" || !pushAuthAddressMatches(address, u.Host) {
		return nil, fail(400, "expected an HTTPS registry address")
	}
	return &url.URL{Scheme: "https", Host: pushRegistryHost(u.Host), Path: "/v2/"}, nil
}

// The registry and its advertised token issuer may have different hosts. Each
// authenticated exchange stays on its original TLS origin, including redirects.
func verifyRegistryLogin(ctx context.Context, transport http.RoundTripper, endpoint *url.URL, config *dockerRegistryAuth) (string, error) {
	client := &http.Client{Transport: registryLoginTransport{transport}, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 || req.URL.Scheme != "https" || req.URL.User != nil || !strings.EqualFold(req.URL.Host, via[0].URL.Host) {
			return http.ErrUseLastResponse
		}
		return nil
	}}
	probe := func(auth string) (int, http.Header, error) {
		r, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
		if err != nil {
			return 0, nil, err
		}
		if auth != "" {
			r.Header.Set("Authorization", auth)
		}
		r.Header.Set("User-Agent", "Micropod Docker Engine")
		resp, err := client.Do(r)
		if err != nil {
			return 0, nil, err
		}
		defer resp.Body.Close()
		return resp.StatusCode, resp.Header, nil
	}
	status, headers, err := probe("")
	if err != nil || status != 401 {
		return "", registryLoginStatus(status, err)
	}
	var header, refresh string
	for _, challenge := range registryauth.ParseAuthHeader(headers) {
		switch challenge.Scheme {
		case registryauth.BearerAuth:
			if config.RegistryToken != "" {
				header = "Bearer " + config.RegistryToken
			} else {
				token, identity, err := registryLoginToken(ctx, client, endpoint.Host, config, challenge)
				if err != nil {
					return "", err
				}
				header, refresh = "Bearer "+token, identity
			}
		case registryauth.BasicAuth:
			if config.Username != "" || config.Password != "" {
				header = "Basic " + base64.StdEncoding.EncodeToString([]byte(config.Username+":"+config.Password))
			}
		}
		if header != "" {
			break
		}
	}
	if header == "" {
		return "", fail(401, "registry requires credentials")
	}
	status, _, err = probe(header)
	if err := registryLoginStatus(status, err); err != nil {
		return "", err
	}
	return refresh, nil
}

// Token JSON and diagnostic bodies come from the remote service. Bound reads
// while retaining the underlying connection's close behavior.
type registryLoginTransport struct{ http.RoundTripper }

func (t registryLoginTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	resp, err := t.RoundTripper.RoundTrip(r)
	if err == nil {
		resp.Body = struct {
			io.Reader
			io.Closer
		}{io.LimitReader(resp.Body, 1<<20), resp.Body}
	}
	return resp, err
}

func registryLoginToken(ctx context.Context, client *http.Client, host string, cfg *dockerRegistryAuth, c registryauth.Challenge) (string, string, error) {
	realm, err := url.Parse(c.Parameters["realm"])
	if err != nil || realm.Scheme != "https" || realm.Hostname() == "" || realm.User != nil || realm.Fragment != "" {
		return "", "", fail(502, "invalid HTTPS registry token issuer")
	}
	opts, err := registryauth.GenerateTokenOptions(ctx, host, cfg.Username, cfg.Password, c)
	if err != nil {
		return "", "", fail(502, "invalid registry challenge")
	}
	opts.FetchRefreshToken = true
	if cfg.IdentityToken == "" {
		t, err := registryauth.FetchToken(ctx, client, nil, opts)
		if err == nil {
			return t.Token, t.RefreshToken, nil
		}
		var remote remoteserrors.ErrUnexpectedStatus
		if !errors.As(err, &remote) || (remote.StatusCode != 404 && remote.StatusCode != 405) {
			return "", "", registryLoginStatus(remote.StatusCode, err)
		}
	} else {
		opts.Username, opts.Secret = "", cfg.IdentityToken
	}
	t, err := registryauth.FetchTokenWithOAuth(ctx, client, nil, "docker", opts)
	if err != nil {
		var remote remoteserrors.ErrUnexpectedStatus
		errors.As(err, &remote)
		return "", "", registryLoginStatus(remote.StatusCode, err)
	}
	return t.AccessToken, t.RefreshToken, nil
}

func registryLoginStatus(status int, err error) error {
	switch {
	case err == nil && status == 200:
		return nil
	case status == 401 || status == 403:
		return fail(401, "registry denied authentication")
	case errors.Is(err, context.DeadlineExceeded):
		return fail(504, "registry authentication timed out")
	default:
		// Do not include remote response bodies, token URLs or credentials.
		return fail(502, "registry authentication service unavailable")
	}
}
