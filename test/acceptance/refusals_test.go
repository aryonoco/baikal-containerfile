// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

package acceptance

import (
	"net/http"
	"testing"

	"github.com/divbast/ci/harness"
)

// refusedExit is the exit status the bootstrap refuses a start with.
const refusedExit = 1

// databaseFaults is the first half of the bash suite's section 13, on s:
// a database that is no longer one, then none at all. Only /healthz sees
// the first, since sabre answers a request with no credentials 401
// without touching the database; the second fails the shipped probe too.
func databaseFaults(t *testing.T, s *harness.Serving) {
	t.Helper()
	harness.RunRecords(t, s.Probe, "damage-db")
	harness.StatusIs(t, s.Health(), "/healthz with the database damaged", http.StatusServiceUnavailable, "/healthz")
	harness.StatusIs(t, s, "/dav.php with the database damaged", http.StatusUnauthorized, "/dav.php")

	harness.RunRecords(t, s.Probe, "remove-db")
	harness.StatusIs(t, s.Health(), "/healthz with the database removed", http.StatusServiceUnavailable, "/healthz")
	const exits = "baikal-health exits 1 with the database removed"
	if code, err := healthProbeExit(t.Context(), s.C); err != nil {
		harness.NewChecks(t).True(exits, false, err.Error())
	} else {
		harness.Equal(harness.NewChecks(t), exits, 1, code)
	}
}

// refusals is the second half of section 13: the starts the bootstrap
// refuses rather than serve. A first start with no admin password would
// have to make one up, and volume, whose database databaseFaults removed,
// holds a config with no database, beside which the bootstrap will not
// make an empty one. Each refuses before there is a server to reach, so
// each runs on no network.
func refusals(t *testing.T, e harness.Engine, image, volume string) {
	t.Helper()
	harness.Refuses(t, e, &harness.RunSpec{
		Image:   image,
		Network: "none",
		Confine: harness.Contract(tmpfsSize),
		Mounts:  onData(newVolume(t, e)),
	}, refusedExit, "cold start with no admin password", "BAIKAL_ADMIN_PASSWORD is required and is not set")
	harness.Refuses(t, e, &harness.RunSpec{
		Image:   image,
		Network: "none",
		Confine: harness.Contract(tmpfsSize),
		Env:     adminEnv(),
		Mounts:  onData(volume),
	}, refusedExit, "config without database", "Refusing to create an empty database beside an existing config")
}
