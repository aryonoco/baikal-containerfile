// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

package acceptance

import (
	"net/http"
	"testing"

	"github.com/divbast/ci/harness"
)

// warmRestart is the bash suite's section 11: the container restarted in
// place, as docker restart or systemd restarts it, comes back serving the
// data it had. A restart empties /tmp, Caddy's state and the probe with
// it, so the bootstrap must start again from /data alone, and not refuse.
// [harness.Serving.Restart] reads the ports again, since Docker binds
// others, and installs the probe again.
func warmRestart(t *testing.T, s *harness.Serving) {
	t.Helper()
	if err := s.Restart(t.Context()); err != nil {
		t.Fatalf("container %s did not come back from a restart: %v", s.C, err)
	}
	harness.StatusIs(t, s, "/dav.php after restart", http.StatusUnauthorized, "/dav.php")
	eventSurvived(t, s, "event survived restart")
	harness.StatusIs(t, s.Health(), "/healthz after restart", http.StatusOK, "/healthz")
}
