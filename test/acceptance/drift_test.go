// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

package acceptance

import (
	"net/http"
	"testing"

	"github.com/divbast/ci/harness"
)

// driftedFrom is the Baikal version driftFrom leaves on the volume: older
// than the image's, and not older than 0.10.0, the oldest the bootstrap
// upgrades from.
const driftedFrom = "0.10.1"

// driftFrom is the first half of version drift, run on the restarted
// container: it records driftedFrom as the version /data was made by, as
// an older image would have left it.
func driftFrom(t *testing.T, s *harness.Serving) {
	t.Helper()
	harness.RunRecords(t, s.Probe, "set-version", driftedFrom)
}

// upgraded is the second half of version drift, on a new container started
// on the drifted volume: the bootstrap runs Baikal's own upgrade, and the
// server answers exactly 401, never the 302 to the install wizard, with
// the event still there.
func upgraded(t *testing.T, s *harness.Serving) {
	t.Helper()
	harness.StatusIs(t, s, "/dav.php after version drift", http.StatusUnauthorized, "/dav.php")
	harness.LogContains(t, s.C, "Baikal's own upgrade ran from "+driftedFrom, "upgraded "+driftedFrom+" -> ")
	harness.RunRecords(t, s.Probe, "assert-current-version")
	eventSurvived(t, s, "event survived the upgrade")
}
