package main

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/containerd/platforms"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// enginePlatform is the one platform this engine runs: the guest is an arm64
// Linux VM with no emulation for other architectures.
const enginePlatform = "linux/arm64"

// checkEnginePlatform accepts a pull's or create's platform when it names
// linux/arm64 in any spelling Docker accepts ("linux/arm64", "linux/arm64/v8",
// "linux/aarch64", "arm64", "linux"). An empty platform means the engine's.
// CRI then selects the image's linux/arm64 entry, from an index pulled by tag,
// by tag@digest or by the index's own digest alike.
//
// Any other platform is refused: an image for another platform could be
// fetched, but never run here, and pulling it would only store bytes no
// container can use. The refusal names the platform asked for and the one the
// engine runs, so a caller asking for linux/amd64 out of habit knows to drop
// the platform (or ask for linux/arm64) to get a multi-arch image's arm64
// variant.
func checkEnginePlatform(raw string) error {
	if raw == "" {
		return nil
	}
	p, err := platforms.Parse(raw)
	if err != nil {
		return fail(http.StatusBadRequest, "invalid platform "+strconv.Quote(raw)+": "+err.Error())
	}
	p = platforms.Normalize(p)
	if p.OS == "linux" && p.Architecture == "arm64" && p.Variant == "" && p.OSVersion == "" && len(p.OSFeatures) == 0 {
		return nil
	}
	return fail(http.StatusBadRequest, "unsupported platform "+platforms.Format(p)+
		": this engine runs "+enginePlatform+" images only (no emulation); ask for no platform, or "+
		enginePlatform+", to use a multi-platform image's "+enginePlatform+" variant")
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
	return fail(http.StatusNotFound, "no matching manifest for "+enginePlatform+" in the manifest list entries: "+
		ref+" has no "+enginePlatform+" image, the only platform this engine runs")
}
