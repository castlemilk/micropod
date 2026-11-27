package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/containerd/platforms"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// enginePlatform is the platform this engine runs natively, and the one a
// pull or create that names no platform gets: the guest is an arm64 Linux VM.
// emulatedPlatform runs too when an x86-64 interpreter is registered
// (emulation_linux.go).
const (
	enginePlatform   = "linux/arm64"
	emulatedPlatform = "linux/amd64"
)

var (
	nativePlatform   = ocispec.Platform{OS: "linux", Architecture: "arm64"}
	amd64Platform    = ocispec.Platform{OS: "linux", Architecture: "amd64"}
	attestationEntry = ocispec.Platform{OS: "unknown", Architecture: "unknown"}
)

// requestedPlatform reads a pull's, create's or build's platform. It returns
// nil when the request names none (the engine's own then applies) and the
// normalized platform otherwise: linux/arm64 in any spelling Docker accepts
// ("linux/arm64", "linux/arm64/v8", "linux/aarch64", "arm64", "linux"), or
// linux/amd64 in any of its spellings ("linux/amd64", "amd64", "x86_64",
// "linux/x86-64", and the v2 and v3 microarchitecture levels, which the
// emulator implements) while x86-64 emulation is available.
//
// Any other platform is refused: an image for it could be fetched, but never
// run here. The refusal names the platform asked for and the ones the engine
// runs, and for linux/amd64 without emulation why emulation is unavailable.
func requestedPlatform(raw string) (*ocispec.Platform, error) {
	if raw == "" {
		return nil, nil
	}
	p, err := platforms.Parse(raw)
	if err != nil {
		return nil, fail(http.StatusBadRequest, "invalid platform "+strconv.Quote(raw)+": "+err.Error())
	}
	p = platforms.Normalize(p)
	if p.OS == "linux" && p.OSVersion == "" && len(p.OSFeatures) == 0 {
		switch {
		case p.Architecture == "arm64" && p.Variant == "":
			native := nativePlatform
			return &native, nil
		case p.Architecture == "amd64" && (p.Variant == "" || p.Variant == "v2" || p.Variant == "v3"):
			if e := currentEmulation(); !e.available() {
				return nil, fail(http.StatusBadRequest, "unsupported platform "+platforms.Format(p)+
					": this engine runs "+enginePlatform+" images only ("+e.unavailableReason()+
					"); ask for no platform, or "+enginePlatform+", to use a multi-platform image's "+enginePlatform+" variant")
			}
			out := amd64Platform
			out.Variant = p.Variant
			return &out, nil
		}
	}
	if !currentEmulation().available() {
		return nil, fail(http.StatusBadRequest, "unsupported platform "+platforms.Format(p)+
			": this engine runs "+enginePlatform+" images only (no emulation); ask for no platform, or "+
			enginePlatform+", to use a multi-platform image's "+enginePlatform+" variant")
	}
	return nil, fail(http.StatusBadRequest, "unsupported platform "+platforms.Format(p)+
		": this engine runs "+enginePlatform+" images, and "+emulatedPlatform+" images through x86-64 emulation")
}

// checkEnginePlatform is requestedPlatform without the result.
func checkEnginePlatform(raw string) error {
	_, err := requestedPlatform(raw)
	return err
}

// isNativePlatform reports whether a request's platform (nil: none) is the
// engine's own.
func isNativePlatform(p *ocispec.Platform) bool {
	return p == nil || p.Architecture == "arm64"
}

// enginePlatforms are the platforms containers run on here, native first.
func enginePlatforms() []string {
	if currentEmulation().available() {
		return []string{enginePlatform, emulatedPlatform}
	}
	return []string{enginePlatform}
}

// pullPlatformError turns CRI's answer for an image with no linux/arm64 entry
// (an index without one, or a single manifest built for another platform)
// into Docker's not-found answer for a pull whose platform the image lacks.
// CRI reports it as a NotFound "no match for platform in manifest <digest>",
// which otherwise reaches the client as a 500 naming no platform at all.
func pullPlatformError(ref string, err error) error {
	st, ok := status.FromError(err)
	if !ok || st.Code() != codes.NotFound || !strings.Contains(st.Message(), "no match for platform") {
		return err
	}
	hint := ", the only platform this engine runs"
	if currentEmulation().available() {
		hint = "; ask for --platform " + emulatedPlatform + " to pull its " + emulatedPlatform + " image, which runs through x86-64 emulation"
	}
	return fail(http.StatusNotFound, "no matching manifest for "+enginePlatform+" in the manifest list entries: "+
		ref+" has no "+enginePlatform+" image"+hint)
}

// imagePlatform is the platform an image's config names, read from CRI's
// verbose status (its "imageSpec" is the OCI config). ok is false when the
// status carries no config.
func imagePlatform(img *cri.ImageStatusResponse) (ocispec.Platform, bool) {
	var details struct {
		ImageSpec *struct {
			OS           string `json:"os"`
			Architecture string `json:"architecture"`
			Variant      string `json:"variant"`
		} `json:"imageSpec"`
	}
	if img == nil || json.Unmarshal([]byte(img.GetInfo()["info"]), &details) != nil || details.ImageSpec == nil ||
		details.ImageSpec.Architecture == "" {
		return ocispec.Platform{}, false
	}
	os := details.ImageSpec.OS
	if os == "" {
		os = "linux"
	}
	return platforms.Normalize(ocispec.Platform{OS: os, Architecture: details.ImageSpec.Architecture, Variant: details.ImageSpec.Variant}), true
}

// platformMatches reports whether an image of platform have satisfies a
// request for want: the same OS and architecture, and a variant the request
// accepts (Docker's own matcher, platforms.Only).
func platformMatches(want, have ocispec.Platform) bool {
	return platforms.Only(want).Match(have)
}

// runsHere reports whether containers of an image of this platform can run on
// this engine now, and why not.
func runsHere(p ocispec.Platform) (bool, string) {
	switch {
	case platforms.OnlyStrict(nativePlatform).Match(p):
		// Strict: the guest kernel runs no 32-bit arm programs (no COMPAT).
		return true, ""
	case p.OS == "linux" && p.Architecture == "amd64":
		if e := currentEmulation(); !e.available() {
			return false, "the image is " + platforms.Format(p) + " and " + e.unavailableReason()
		}
		return true, ""
	default:
		return false, "the image is " + platforms.Format(p) + "; this engine runs " + strings.Join(enginePlatforms(), " and ") + " images"
	}
}
