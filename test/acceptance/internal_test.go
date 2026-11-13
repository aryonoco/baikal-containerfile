// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

package acceptance

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/divbast/ci/harness"
)

// loopbackOrigin is the app port from inside the container.
const loopbackOrigin = "http://127.0.0.1:8080"

// The record that says the server answers from inside the container, and
// how long it is given to. The contract has already seen the app port
// answer GET /, so this is the bash suite's own wait, kept for its record.
const (
	servingWithin = 60 * time.Second
	servingWhat   = "server answers on " + loopbackOrigin + "/dav.php within 60s"
)

// internalChecks are the checks the bash suite made from inside a
// container on a network with no route out. The contract's own container
// is on such a network, so they run there, from its ReadyProbe, once both
// ports answer, and are reported after the contract's checks. records is
// what they found, and err why they stopped, if they did.
type internalChecks struct {
	records []harness.Record
	err     error
}

// newInternalChecks returns checks not yet run, which say so if they never
// are.
func newInternalChecks() *internalChecks {
	return &internalChecks{err: errors.New("the container under the contract never came up, so nothing was asked from inside it")}
}

// run is the contract's ReadyProbe: it waits for /dav.php to answer from
// inside the container, which is all ready means, then adds a DAV user and
// asks DAV, unauthenticated and as that user, from inside the container,
// through the probe's socket http-request, never PHP's fopen wrapper. Only
// a server that never answers is an error, which fails every check of the
// contract's; anything else is a record, or an error of its own, reported
// after them.
func (ic *internalChecks) run(ctx context.Context, _ *harness.Container, p *harness.Probe) error {
	ic.err = nil
	served := harness.Record{What: servingWhat, Expected: "an HTTP status"}
	resp, err := p.WaitHTTP(ctx, loopbackOrigin+"/dav.php", servingWithin)
	if err != nil {
		served.Found = err.Error()
		ic.records = append(ic.records, served)
		return err
	}
	served.OK, served.Found = true, strconv.Itoa(resp.Status)
	ic.records = append(ic.records, served)
	ic.err = ic.ask(ctx, p)
	return nil
}

// ask adds alice to the container p is in, and asks DAV from inside it,
// recording what each answered. The error is for a probe that could not
// add her at all.
func (ic *internalChecks) ask(ctx context.Context, p *harness.Probe) error {
	seeded, err := p.Run(ctx, "seed-user", davUser, davPassword)
	if err != nil {
		return err
	}
	ic.records = append(ic.records, seeded...)

	ic.loopback(ctx, p, "unauthenticated GET /dav.php from inside the container",
		http.MethodGet, "/dav.php", nil, http.StatusUnauthorized)
	ic.loopback(ctx, p, "authenticated PROPFIND "+principalPath+" from inside the container",
		methodPropfind, principalPath, []string{"Depth: 0", "Authorization: " + basicAuth()}, http.StatusMultiStatus)
	return nil
}

// loopback records whether method path, sent from inside the container
// with headers, answers exactly want.
func (ic *internalChecks) loopback(ctx context.Context, p *harness.Probe, what, method, path string, headers []string, want int) {
	rec := harness.Record{What: what, Expected: strconv.Itoa(want)}
	if resp, err := p.HTTP(ctx, method, loopbackOrigin+path, headers, ""); err != nil {
		rec.Found = "no answer: " + err.Error()
	} else {
		rec.OK, rec.Found = resp.Status == want, strconv.Itoa(resp.Status)
	}
	ic.records = append(ic.records, rec)
}

// report reports what the checks found, as checks of t's, and why they
// stopped, if they did.
func (ic *internalChecks) report(t *testing.T) {
	t.Helper()
	if len(ic.records) > 0 {
		harness.NewChecks(t).Records(ic.records)
	}
	if ic.err != nil {
		t.Errorf("FAIL the checks inside the contract's internal network: %v", ic.err)
	}
}
