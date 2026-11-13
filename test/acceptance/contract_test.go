// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

package acceptance

import (
	"slices"
	"testing"
	"time"

	"github.com/divbast/baikal-oci-image/test/probe"
	"github.com/divbast/ci/contract"
	"github.com/divbast/ci/harness"
)

// What Baikal's contract says of every container here.
const (
	// tmpfsSize is the size of /tmp the README states. Every container
	// gets exactly this, so no check passes on more room than the
	// contract grants.
	tmpfsSize = "512m"
	// appPort serves DAV, and healthPort only /healthz.
	appPort    = 8080
	healthPort = 8081
)

// serverArgv is the server's argv: what the bootstrap hands over to, with
// pcntl_exec(SERVER_BIN, ['run', '--config', CADDYFILE]).
var serverArgv = []string{harness.FrankenPHP, "run", "--config", "/etc/caddy/Caddyfile"}

// healthCmd is the shipped health probe, as the image's HEALTHCHECK runs
// it and a Podman user passes it with --health-cmd.
var healthCmd = []string{harness.FrankenPHP, "php-cli", "/usr/local/bin/baikal-health"}

// TestContract runs divbast's confinement contract against the image, on a
// network with no route out: no capability, a read-only root, uid 65532,
// the server as PID 1, no shell, two listeners, no egress, the HEALTHCHECK
// and the health port. Its container also gets the internal checks,
// which ask DAV from inside that network: Baikal serves there, so egress
// refused there is the refusal of a server that works.
func TestContract(t *testing.T) {
	t.Parallel()
	e, image := underTest(t)
	internal := newInternalChecks()
	contract.Run(t, &contract.Config{
		Image:      image,
		AppPort:    appPort,
		HealthPort: healthPort,
		TmpfsSize:  tmpfsSize,
		PID1:       serverArgv,
		HealthCmd:  healthCmd,
		Healthcheck: contract.Healthcheck{
			Test:        slices.Concat([]string{"CMD"}, healthCmd),
			Interval:    30 * time.Second,
			Timeout:     10 * time.Second,
			StartPeriod: 60 * time.Second,
			Retries:     3,
		},
		// A first start on an empty volume refuses without the password
		Env: adminEnv(),
		Mounts: func(tb testing.TB) []harness.Mount {
			tb.Helper()
			return onData(newVolume(tb, e))
		},
		// The health port's root, and DAV's own entry point: neither may
		// answer there
		HealthOnly404: []string{"/", "/dav.php"},
		ProbeApp:      probe.App,
		ReadyProbe:    internal.run,
	})
	internal.report(t)
}
