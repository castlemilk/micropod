package main

import (
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

func TestObserveCacheDiskReportsDeviceMountAndUnknown(t *testing.T) {
	dir := t.TempDir()
	oldDevice, oldInfo, oldRoot := cacheDiskDevice, mountInfoPath, cacheRoot
	t.Cleanup(func() { cacheDiskDevice, mountInfoPath, cacheRoot = oldDevice, oldInfo, oldRoot })
	cacheRoot = filepath.Join(dir, "caches")
	if err := os.MkdirAll(cacheRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	cacheDiskDevice = filepath.Join(dir, "vdb")
	mountInfoPath = filepath.Join(dir, "mountinfo")

	// No device: no cache disk attached.
	if got := observeCacheDisk(); got == nil || got.Mounted || got.Device != "" {
		t.Fatalf("without a device: %+v", got)
	}
	if err := os.WriteFile(cacheDiskDevice, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	// Device but unreadable mountinfo: the guest cannot tell.
	if got := observeCacheDisk(); got != nil {
		t.Fatalf("without mountinfo: %+v, want nil", got)
	}
	// Attached but the mount failed: caches live on the root disk.
	line := "35 22 254:16 / " + cacheRoot + " rw - ext4 /dev/vda rw\n"
	if err := os.WriteFile(mountInfoPath, []byte(line), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := observeCacheDisk(); got == nil || got.Mounted || got.Device != cacheDiskDevice {
		t.Fatalf("mount on another device: %+v", got)
	}
	line = "35 22 254:16 / " + cacheRoot + " rw - ext4 " + cacheDiskDevice + " rw\n"
	if err := os.WriteFile(mountInfoPath, []byte(line), 0o600); err != nil {
		t.Fatal(err)
	}
	got := observeCacheDisk()
	if got == nil || !got.Mounted || got.SizeBytes == 0 {
		t.Fatalf("mounted: %+v", got)
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
