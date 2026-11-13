// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

package acceptance

import (
	"context"
	"encoding/base64"
	"fmt"
	"maps"
	"net/http"
	"testing"
	"time"

	"github.com/divbast/baikal-oci-image/test/probe"
	"github.com/divbast/ci/harness"
)

// adminPassword is BAIKAL_ADMIN_PASSWORD, which a first start on an empty
// volume refuses without.
const adminPassword = "correct horse battery staple"

// userSpec is how a user runs image, as the README has them: under the
// contract, with the admin password and volume at /data. It publishes the
// health port too, which a deployment keeps unpublished, only so the
// suite can ask it from the host, and gives Podman the --health-cmd a
// Podman user passes. The server is ready once GET /dav.php answers.
func userSpec(image, volume string) *harness.ServeSpec {
	return &harness.ServeSpec{
		Run: harness.RunSpec{
			Image:     image,
			Confine:   harness.Contract(tmpfsSize),
			Env:       adminEnv(),
			Mounts:    onData(volume),
			HealthCmd: healthCmd,
		},
		AppPort:    appPort,
		HealthPort: healthPort,
		ReadyPath:  "/dav.php",
		ProbeApp:   probe.App,
	}
}

// adminEnv is the environment a first start needs.
func adminEnv() map[string]string {
	return map[string]string{"BAIKAL_ADMIN_PASSWORD": adminPassword}
}

// dataDir is the one volume the image needs: everything that outlives a
// start lives there.
const dataDir = "/data"

// onData mounts volume at /data.
func onData(volume string) []harness.Mount {
	return []harness.Mount{{Source: volume, Target: dataDir, Volume: true}}
}

// newVolume makes a volume for tb, removed when tb ends, or fails tb.
func newVolume(tb testing.TB, e harness.Engine) string {
	tb.Helper()
	v, err := e.Volume(tb.Context(), tb, "")
	if err != nil {
		tb.Fatal(err)
	}
	return v
}

// serve serves sp with [harness.Engine.Serve]: it returns once
// sp.ReadyPath answers and the probe is installed. It fails t at once if
// the server never serves, since every check after would fail for that
// one reason.
func serve(t *testing.T, e harness.Engine, sp *harness.ServeSpec) *harness.Serving {
	t.Helper()
	s, err := e.Serve(t.Context(), t, sp)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// serveNamed is serve, with its serving a check of its own, named what.
func serveNamed(t *testing.T, e harness.Engine, sp *harness.ServeSpec, what string) *harness.Serving {
	t.Helper()
	s, err := e.Serve(t.Context(), t, sp)
	if err != nil {
		harness.NewChecks(t).True(what, false, err.Error())
		t.FailNow()
	}
	harness.NewChecks(t).True(what, true, "GET "+sp.ReadyPath+" answered")
	return s
}

// basicAuth is the Authorization header's value for alice.
func basicAuth() string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(davUser+":"+davPassword))
}

// dav sends method path to s's app port from the host as alice, with
// header and body, and reads the answer. An empty body sends none.
func dav(ctx context.Context, s *harness.Serving, method, path string, header http.Header, body string) (harness.Response, error) {
	h := http.Header{"Authorization": {basicAuth()}}
	maps.Copy(h, header)
	var b []byte
	if body != "" {
		b = []byte(body)
	}
	return s.Do(ctx, nil, method, path, h, b)
}

// putEvent puts the event in alice's calendar.
func putEvent(ctx context.Context, s *harness.Serving) (harness.Response, error) {
	return dav(ctx, s, http.MethodPut, eventPath, http.Header{"Content-Type": {"text/calendar"}}, event)
}

// eventSurvived checks GET of the event, as alice, gives it back.
func eventSurvived(t *testing.T, s *harness.Serving, what string) {
	t.Helper()
	resp, err := dav(t.Context(), s, http.MethodGet, eventPath, nil, "")
	if err != nil {
		harness.NewChecks(t).True(what, false, err.Error())
		return
	}
	harness.Contains(t, what, eventSummary, string(resp.Body))
}

// engineHealthy checks the engine's own verdict on c, which it reaches on
// its own schedule, as it would for a user: Docker runs the image's
// HEALTHCHECK, and Podman the --health-cmd it was given, from the systemd
// timer it sets up for it. A shell-form command needs /bin/sh, which the
// image lacks, so only the exec form can pass. The engine must say healthy
// within the image's start period and three of its intervals, the window
// the contract's own engine-healthy check gives it.
func engineHealthy(t *testing.T, e harness.Engine, image string, c *harness.Container, what string) {
	t.Helper()
	ctx := t.Context()
	var startPeriod time.Duration
	if cfg, err := e.ImageConfig(ctx, t, image); err != nil {
		t.Errorf("reading the image's HEALTHCHECK: %v", err)
	} else if cfg.Healthcheck != nil {
		startPeriod = cfg.Healthcheck.StartPeriod
	}
	found := "healthy"
	if err := c.EngineHealthy(ctx, startPeriod); err != nil {
		found = err.Error()
	}
	harness.Equal(harness.NewChecks(t), what, "healthy", found)
}

// healthProbeExit runs the shipped probe in c, as HEALTHCHECK runs it, and
// returns its exit status, or an error saying what it printed when the
// engine could not run it.
func healthProbeExit(ctx context.Context, c *harness.Container) (int, error) {
	res, err := c.Exec(ctx, nil, healthCmd...)
	if err != nil {
		return 0, fmt.Errorf("running %s in container %s: %w", healthCmd[len(healthCmd)-1], c, err)
	}
	return res.Code, nil
}
