// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

package acceptance

import (
	"net/http"
	"testing"

	"github.com/divbast/baikal-oci-image/test/probe"
	"github.com/divbast/ci/harness"
)

// The images whose volumes this image must serve. Each is history, pinned
// by digest so it can never move, and no update may ever change either:
// renovate.json ignores ghcr.io/divbast/baikal.
const (
	// previousImage is the last Baikal 0.12.1 image published before the
	// move to divbast, copied into divbast/baikal byte for byte. Upstream's
	// upgrade is cumulative, so a volume it made runs through every
	// migration Baikal has added since, on every release.
	previousImage = "ghcr.io/divbast/baikal@sha256:62ef30cda439a70d457e82126ba4c15b036fdde33937fc20d17f5533af79a466"
	// preMoveImage is the last image published before Baikal moved onto
	// divbast/ci's shared build: Baikal 0.13.0, built from f235a10, the
	// :latest every user ran on that day.
	preMoveImage = "ghcr.io/divbast/baikal@sha256:8f2bbc028ddcc1546f8b6a8aabd8fec1e8ddeb4be1350de9995b43aa441f4335"
)

// The contact the pre-move image is given, and the line of it a GET must
// give back.
const (
	contactPath = addressbookPath + "pre-move-1.vcf"
	contact     = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:pre-move-1\r\nFN:Pre Move\r\nN:Move;Pre;;;\r\n" +
		"EMAIL:pre.move@example.org\r\nEND:VCARD\r\n"
	contactName = "FN:Pre Move"
)

// olderSpec is how an image published before this one is run to make the
// data this one must serve: as the bash suite ran it, under the contract
// with the admin password and volume at /data, and only the app port
// published. The probe goes in too, since its subcommands write what DAV
// cannot, so the probe and its app.php must load in that image's PHP.
func olderSpec(image, volume string) *harness.ServeSpec {
	return &harness.ServeSpec{
		Run: harness.RunSpec{
			Image:   image,
			Confine: harness.Contract(tmpfsSize),
			Env:     adminEnv(),
			Mounts:  onData(volume),
		},
		AppPort:   appPort,
		ReadyPath: "/dav.php",
		ProbeApp:  probe.App,
	}
}

// TestUpgradeFromPrevious is the bash suite's section 14: data the 0.12.1
// image made, through DAV and in the shape older schemas allowed, comes
// through this image's upgrade whole, into a database indistinguishable
// from a fresh install's.
//
//nolint:paralleltest,tparallel // this image serves the volume the previous image wrote, once that one is gone
func TestUpgradeFromPrevious(t *testing.T) {
	t.Parallel()
	e, image := underTest(t)
	volume := newVolume(t, e)

	t.Run("previous-image", func(t *testing.T) {
		s := serveNamed(t, e, olderSpec(previousImage, volume), "the published image serves")
		ctx := t.Context()
		harness.RunRecords(t, s.Probe, "seed-user", davUser, davPassword)
		harness.RunRecords(t, s.Probe, "seed-user", sharee, shareePass)
		resp, err := dav(ctx, s, methodMkcalendar, calendarPath, nil, "")
		harness.Answers(t, "MKCALENDAR on the published image", http.StatusCreated, resp, err)
		resp, err = putEvent(ctx, s)
		harness.Answers(t, "PUT event on the published image", http.StatusCreated, resp, err)
		// The shape a share had before 0.13.0, which its migration rebuilds
		harness.RunRecords(t, s.Probe, "seed-share", davUser, sharee, "null")
	})
	t.Run("this-image", func(t *testing.T) {
		s := serveNamed(t, e, userSpec(image, volume), "this image serves the upgraded volume")
		harness.StatusIs(t, s, "/dav.php after the upgrade", http.StatusUnauthorized, "/dav.php")
		harness.StatusIs(t, s.Health(), "/healthz after the upgrade", http.StatusOK, "/healthz")
		harness.RunRecords(t, s.Probe, "assert-current-version")
		harness.RunRecords(t, s.Probe, "assert-schema")
		harness.RunRecords(t, s.Probe, "assert-share", davUser, sharee)
		eventSurvived(t, s, "event from the published image survived the upgrade")
	})
}

// TestServesPreMoveVolume checks a user moving from the last image
// published before the shared build to this one keeps every calendar,
// contact and share, and that the bootstrap neither refuses the volume
// nor serves the install wizard: /dav.php answers exactly 401, never the
// 302 to it, and /healthz 200.
//
//nolint:paralleltest,tparallel // this image serves the volume the pre-move image wrote, once that one is gone
func TestServesPreMoveVolume(t *testing.T) {
	t.Parallel()
	e, image := underTest(t)
	volume := newVolume(t, e)

	t.Run("pre-move-image", func(t *testing.T) {
		s := serveNamed(t, e, olderSpec(preMoveImage, volume), "the pre-move image serves")
		ctx := t.Context()
		harness.RunRecords(t, s.Probe, "seed-user", davUser, davPassword)
		harness.RunRecords(t, s.Probe, "seed-user", sharee, shareePass)
		resp, err := dav(ctx, s, methodMkcalendar, calendarPath, nil, "")
		harness.Answers(t, "MKCALENDAR on the pre-move image", http.StatusCreated, resp, err)
		resp, err = putEvent(ctx, s)
		harness.Answers(t, "PUT event on the pre-move image", http.StatusCreated, resp, err)
		// 0.13.0's schema takes a share only in the shape sabre writes one
		harness.RunRecords(t, s.Probe, "seed-share", davUser, sharee, "accepted")
		resp, err = dav(ctx, s, methodMkcol, addressbookPath, http.Header{"Content-Type": {"application/xml"}}, mkcolAddressbook)
		harness.Answers(t, "MKCOL addressbook on the pre-move image", http.StatusCreated, resp, err)
		resp, err = dav(ctx, s, http.MethodPut, contactPath, http.Header{"Content-Type": {"text/vcard"}}, contact)
		harness.Answers(t, "PUT contact on the pre-move image", http.StatusCreated, resp, err)
	})
	t.Run("this-image", func(t *testing.T) {
		s := serveNamed(t, e, userSpec(image, volume), "this image serves the pre-move volume")
		harness.StatusIs(t, s, "/dav.php after the move", http.StatusUnauthorized, "/dav.php")
		harness.StatusIs(t, s.Health(), "/healthz after the move", http.StatusOK, "/healthz")
		harness.RunRecords(t, s.Probe, "assert-current-version")
		harness.RunRecords(t, s.Probe, "assert-share", davUser, sharee)
		eventSurvived(t, s, "event from the pre-move image survived the move")
		const what = "contact from the pre-move image survived the move"
		if resp, err := dav(t.Context(), s, http.MethodGet, contactPath, nil, ""); err != nil {
			harness.NewChecks(t).True(what, false, err.Error())
		} else {
			harness.Contains(t, what, contactName, string(resp.Body))
		}
	})
}
