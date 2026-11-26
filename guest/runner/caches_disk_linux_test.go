package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMountedOnMatchesSourceAndTarget(t *testing.T) {
	info := []byte(strings.Join([]string{
		"22 1 254:0 / / rw,noatime - ext4 /dev/vda rw",
		"35 22 254:16 / /var/lib/micropod/caches rw,noatime - ext4 /dev/vdb rw",
		"36 22 0:30 / /var/lib/micropod/buildkit rw - ext4 /dev/vdb rw",
		"37 22 0:31 / /mnt/with\\040space rw - ext4 /dev/vdc rw",
	}, "\n"))
	cases := []struct {
		source, target string
		want           bool
	}{
		{"/dev/vdb", "/var/lib/micropod/caches", true},
		{"/dev/vda", "/var/lib/micropod/caches", false},
		{"/dev/vdb", "/var/lib/micropod", false},
		{"/dev/vdc", "/mnt/with space", true},
	}
	for _, c := range cases {
		if got := mountedOn(info, c.source, c.target); got != c.want {
			t.Errorf("mountedOn(%s, %s) = %v, want %v", c.source, c.target, got, c.want)
		}
	}
}

func TestObserveCacheDiskReportsInitDeviceMountAndUnknown(t *testing.T) {
	dir := t.TempDir()
	oldDevice, oldInfo, oldRoot, oldInit := cacheDiskDevice, mountInfoPath, cacheRoot, cacheDiskInit
	t.Cleanup(func() {
		cacheDiskDevice, mountInfoPath, cacheRoot, cacheDiskInit = oldDevice, oldInfo, oldRoot, oldInit
	})
	cacheRoot = filepath.Join(dir, "caches")
	if err := os.MkdirAll(cacheRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	cacheDiskDevice = filepath.Join(dir, "vdb")
	mountInfoPath = filepath.Join(dir, "mountinfo")

	// No device and no word from guest init: no cache disk attached.
	cacheDiskInit = ""
	if got := observeCacheDisk(); got != (cacheDiskState{State: "none"}) {
		t.Fatalf("without a device: %+v", got)
	}
	// Guest init found the attached disk missing: shared caches are off.
	cacheDiskInit = "unavailable"
	if got := observeCacheDisk(); got != (cacheDiskState{State: "unavailable"}) {
		t.Fatalf("missing device: %+v", got)
	}
	if err := os.WriteFile(cacheDiskDevice, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	// Device but unreadable mountinfo: the guest cannot tell, so not mounted.
	cacheDiskInit = "mounted"
	if got := observeCacheDisk(); got.Mounted || got.MountInfoError == "" || got.Device != cacheDiskDevice || got.State != "mounted" {
		t.Fatalf("without mountinfo: %+v", got)
	}
	// Attached but the mount failed: what mountinfo shows is another device.
	cacheDiskInit = "unavailable"
	line := "35 22 254:16 / " + cacheRoot + " rw - ext4 /dev/vda rw\n"
	if err := os.WriteFile(mountInfoPath, []byte(line), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := observeCacheDisk(); got.Mounted || got.MountInfoError != "" || got.Device != cacheDiskDevice || got.State != "unavailable" {
		t.Fatalf("mount on another device: %+v", got)
	}
	cacheDiskInit = "mounted"
	line = "35 22 254:16 / " + cacheRoot + " rw - ext4 " + cacheDiskDevice + " rw\n"
	if err := os.WriteFile(mountInfoPath, []byte(line), 0o600); err != nil {
		t.Fatal(err)
	}
	got := observeCacheDisk()
	if !got.Mounted || got.SizeBytes == 0 || got.State != "mounted" {
		t.Fatalf("mounted: %+v", got)
	}
}

// The inventory carries the cache disk object every time, with the reason
// shared caches are off at its top level, so the host's CLI, rig health and
// `micropod cache status` read one shape.
func TestCacheInventoryReportsTheCacheDiskAndWhyCachesAreOff(t *testing.T) {
	useCacheRoot(t)
	oldDevice, oldInit := cacheDiskDevice, cacheDiskInit
	t.Cleanup(func() { cacheDiskDevice, cacheDiskInit = oldDevice, oldInit })
	cacheDiskDevice = filepath.Join(t.TempDir(), "absent")
	eng := &dockerEngine{}
	for _, c := range []struct {
		init, state string
		off         bool
	}{{"", "none", false}, {"unavailable", "unavailable", true}} {
		cacheDiskInit = c.init
		raw, err := json.Marshal(eng.inspectCaches(false))
		if err != nil {
			t.Fatal(err)
		}
		var got struct {
			CacheDisk   *cacheDiskState `json:"cacheDisk"`
			Unavailable *string         `json:"unavailable"`
		}
		if err := json.Unmarshal(raw, &got); err != nil {
			t.Fatal(err)
		}
		if got.CacheDisk == nil || got.CacheDisk.State != c.state || got.CacheDisk.Mounted {
			t.Fatalf("%q: cacheDisk %+v in %s", c.init, got.CacheDisk, raw)
		}
		if (got.Unavailable != nil) != c.off {
			t.Fatalf("%q: unavailable %v in %s", c.init, got.Unavailable, raw)
		}
	}
}

func TestCachePruneWithoutDryRunIsADryRun(t *testing.T) {
	eng := &dockerEngine{}
	oldRoot := cacheRoot
	t.Cleanup(func() { cacheRoot = oldRoot })
	cacheRoot = t.TempDir()
	for _, c := range []struct {
		name, target, body string
		wantDryRun         bool
	}{
		{"empty body", "/micropod/caches/prune", "", true},
		{"no dryRun key", "/micropod/caches/prune", `{"scope":"s1"}`, true},
		{"explicit apply", "/micropod/caches/prune", `{"dryRun":false}`, false},
		{"explicit dry run", "/micropod/caches/prune", `{"dryRun":true}`, true},
		{"query apply", "/micropod/caches/prune?dry_run=0", "", false},
		{"query dry run", "/micropod/caches/prune?dry_run=1", `{"dryRun":false}`, true},
	} {
		rr := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, c.target, strings.NewReader(c.body))
		handled, err := cacheRoutes(eng, rr, req, "POST", "micropod/caches/prune")
		if !handled || err != nil || rr.Code != 200 {
			t.Fatalf("%s: handled=%v err=%v code=%d", c.name, handled, err, rr.Code)
		}
		if got := strings.Contains(rr.Body.String(), `"dryRun":true`); got != c.wantDryRun {
			t.Errorf("%s: reply %s, want dryRun %v", c.name, rr.Body.String(), c.wantDryRun)
		}
	}
}
