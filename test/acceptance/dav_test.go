// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

package acceptance

import (
	"net/http"
	"testing"

	"github.com/divbast/ci/harness"
)

// The DAV user the suite adds, and the one alice shares her calendar
// with.
const (
	davUser, davPassword = "alice", "wonderland"
	sharee, shareePass   = "bob", "builder"
)

// Where alice's things are.
const (
	principalPath   = "/dav.php/principals/" + davUser + "/"
	calendarPath    = "/dav.php/calendars/" + davUser + "/test/"
	eventPath       = calendarPath + "accept-1.ics"
	addressbookPath = "/dav.php/addressbooks/" + davUser + "/contacts/"
)

// The DAV methods net/http has no name for.
const (
	methodPropfind   = "PROPFIND"
	methodMkcalendar = "MKCALENDAR"
	methodReport     = "REPORT"
	methodMkcol      = "MKCOL"
)

// event is the event the suite puts, and eventSummary the line of it a
// GET must give back.
const (
	event = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//acceptance//EN\r\nBEGIN:VEVENT\r\nUID:accept-1\r\n" +
		"DTSTAMP:20260101T000000Z\r\nDTSTART:20260101T120000Z\r\nDTEND:20260101T130000Z\r\nSUMMARY:acceptance\r\n" +
		"END:VEVENT\r\nEND:VCALENDAR\r\n"
	eventSummary = "SUMMARY:acceptance"
)

// The bodies of the REPORT and the extended MKCOL, as a client sends them.
const (
	syncCollection = `<?xml version="1.0"?><d:sync-collection xmlns:d="DAV:"><d:sync-token/>` +
		`<d:prop><d:getetag/></d:prop></d:sync-collection>`
	mkcolAddressbook = `<?xml version="1.0"?><d:mkcol xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav">` +
		`<d:set><d:prop><d:resourcetype><d:collection/><c:addressbook/></d:resourcetype></d:prop></d:set></d:mkcol>`
)

// TestDAV runs the image as a user would, on one volume, in phases
// ported from the earlier bash suite (in git history), in its order: a
// cold start and DAV, a restart of the same container, version drift, a
// damaged and then a missing database, and the starts the bootstrap
// refuses. Each phase starts from what the one before it left on the
// volume.
//
//nolint:paralleltest,tparallel // every phase runs on the volume the one before it wrote, so they run in turn
func TestDAV(t *testing.T) {
	t.Parallel()
	e, image := underTest(t)
	volume := newVolume(t, e)

	// The restart and the drift act on the container the cold start ran,
	// which is removed once they have.
	t.Run("first-start", func(t *testing.T) {
		s := serveNamed(t, e, userSpec(image, volume), "container serves")
		t.Run("cold-start", func(t *testing.T) { coldStart(t, e, image, s) })
		t.Run("warm-restart", func(t *testing.T) { warmRestart(t, s) })
		t.Run("drift-from", func(t *testing.T) { driftFrom(t, s) })
	})
	t.Run("after-drift", func(t *testing.T) {
		s := serve(t, e, userSpec(image, volume))
		t.Run("upgraded", func(t *testing.T) { upgraded(t, s) })
		t.Run("database-faults", func(t *testing.T) { databaseFaults(t, s) })
	})
	t.Run("refusals", func(t *testing.T) { refusals(t, e, image, volume) })
}

// coldStart is a first start on an empty volume, on s: the exact 401,
// the health port from the host, the engine's own health check, and DAV,
// CalDAV and CardDAV working. The contract's checks cover the
// confinement.
func coldStart(t *testing.T, e harness.Engine, image string, s *harness.Serving) {
	t.Helper()
	checks := harness.NewChecks(t)
	ctx := t.Context()

	harness.StatusIs(t, s, "/dav.php", http.StatusUnauthorized, "/dav.php")
	harness.StatusIs(t, s.Health(), "/healthz", http.StatusOK, "/healthz")
	if resp, err := s.Health().Get(ctx, "/healthz", nil); err != nil {
		checks.True("/healthz says ok", false, err.Error())
	} else {
		harness.Contains(t, "/healthz says ok", "ok", string(resp.Body))
	}
	engineHealthy(t, e, image, s.C, "engine reports the container healthy")

	harness.RunRecords(t, s.Probe, "seed-user", davUser, davPassword)
	resp, err := dav(ctx, s, methodPropfind, principalPath, http.Header{"Depth": {"0"}}, "")
	harness.Answers(t, "authenticated PROPFIND", http.StatusMultiStatus, resp, err)
	resp, err = dav(ctx, s, methodMkcalendar, calendarPath, nil, "")
	harness.Answers(t, "MKCALENDAR", http.StatusCreated, resp, err)
	resp, err = putEvent(ctx, s)
	harness.Answers(t, "PUT event", http.StatusCreated, resp, err)
	eventSurvived(t, s, "GET event round-trips")
	resp, err = dav(ctx, s, methodReport, calendarPath,
		http.Header{"Depth": {"1"}, "Content-Type": {"application/xml"}}, syncCollection)
	harness.Answers(t, "REPORT sync-collection", http.StatusMultiStatus, resp, err)

	resp, err = dav(ctx, s, methodMkcol, addressbookPath, http.Header{"Content-Type": {"application/xml"}}, mkcolAddressbook)
	harness.Answers(t, "MKCOL addressbook", http.StatusCreated, resp, err)

	// RFC 6764 discovery, which Caddy answers itself
	harness.StatusIs(t, s, "/.well-known/caldav", http.StatusMovedPermanently, "/.well-known/caldav")
	harness.StatusIs(t, s, "/.well-known/carddav", http.StatusMovedPermanently, "/.well-known/carddav")
}
