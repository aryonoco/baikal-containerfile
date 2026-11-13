// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

package acceptance

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/divbast/ci/harness"
)

// largePhotoBytes is the size of the photo in the vCard
// TestLargeObjectRoundTrips puts, before base64 makes it a third larger:
// a card of over 3 MiB, as a contact with a photo can be. PHP keeps 16 KiB
// of a request body in memory and spools the rest to /tmp, so the card is
// written there while it is handled, twice over.
const largePhotoBytes = (3 << 20) * 3 / 4

// bodyCap is the most of a request body Caddy lets through on :8080, as
// the Caddyfile's request_body sets it: 64MB, which Caddy reads as
// 64,000,000 bytes. /tmp holds eight times that.
const bodyCap = 64_000_000

// tmpSlack is how much more /tmp may hold after a request than before it:
// room for the PHP session file a request may leave, and none for the
// body.
const tmpSlack = 1 << 20

// continueWithin is how long the over-cap PUT that declares its length
// waits for the server to take its body, as Expect: 100-continue asks,
// before it sends the body anyway: as long as the whole request may take,
// so a slow answer never has the client streaming the body into a
// connection the server is about to reset.
const continueWithin = 30 * time.Second

// Where the uploads go, in alice's addressbook.
const (
	largeCardPath = addressbookPath + "large-1.vcf"
	overCapPath   = addressbookPath + "over-cap.vcf"
)

// TestLargeObjectRoundTrips puts a vCard far bigger than the body PHP
// keeps in memory, and checks it is stored and given back byte for byte,
// on the /tmp the README sizes, which then holds no more than it did.
func TestLargeObjectRoundTrips(t *testing.T) {
	t.Parallel()
	e, image := underTest(t)
	s := serve(t, e, userSpec(image, newVolume(t, e)))
	withAddressbook(t, s)
	ctx := t.Context()
	before := tmpUsedNow(t, s.C)

	card := largeCard()
	resp, err := dav(ctx, s, http.MethodPut, largeCardPath, http.Header{"Content-Type": {"text/vcard"}}, string(card))
	harness.Answers(t, "PUT a vCard of over 3 MiB", http.StatusCreated, resp, err)

	const what = "GET the vCard of over 3 MiB gives back every byte put"
	if resp, err := dav(ctx, s, http.MethodGet, largeCardPath, nil, ""); err != nil {
		harness.NewChecks(t).True(what, false, err.Error())
	} else {
		harness.NewChecks(t).True(what, resp.Status == http.StatusOK && bytes.Equal(resp.Body, card),
			fmt.Sprintf("status %d, %d bytes back of %d put", resp.Status, len(resp.Body), len(card)))
	}
	tmpBack(t, s.C, "/tmp use after the large PUT is back within 1 MiB of where it was", before)
}

// TestBodyOverCapRefused puts a body one byte over the cap, and checks it
// is refused with 413, never a 500, that the server goes on serving, and
// that /tmp is left as it was found. Caddy refuses a body whose
// Content-Length says it is too big before PHP reads any of it; one sent
// chunked, with no length, it cuts off at the cap, and refuses the same
// way. /tmp is read last, so PHP has long finished with what it spooled.
func TestBodyOverCapRefused(t *testing.T) {
	t.Parallel()
	e, image := underTest(t)
	s := serve(t, e, userSpec(image, newVolume(t, e)))
	withAddressbook(t, s)
	ctx := t.Context()
	before := tmpUsedNow(t, s.C)

	resp, err := putOverCap(ctx, s, bodyCap+1)
	harness.Answers(t, "PUT one byte over the 64MB request body cap", http.StatusRequestEntityTooLarge, resp, err)
	resp, err = putOverCap(ctx, s, -1)
	harness.Answers(t, "PUT one byte over the 64MB request body cap, chunked with no Content-Length",
		http.StatusRequestEntityTooLarge, resp, err)
	harness.StatusIs(t, s, "/dav.php after the refused PUTs", http.StatusUnauthorized, "/dav.php")
	tmpBack(t, s.C, "/tmp use after the refused PUTs is back within 1 MiB of where it was", before)
}

// withAddressbook adds alice, and her addressbook, to s, or fails t: what
// the uploads are put in.
func withAddressbook(t *testing.T, s *harness.Serving) {
	t.Helper()
	ctx := t.Context()
	records, err := s.Probe.Run(ctx, "seed-user", davUser, davPassword)
	if err == nil && slices.ContainsFunc(records, func(r harness.Record) bool { return !r.OK }) {
		err = fmt.Errorf("seed-user found %+v", records)
	}
	if err != nil {
		t.Fatalf("adding %s: %v", davUser, err)
	}
	resp, err := dav(ctx, s, methodMkcol, addressbookPath, http.Header{"Content-Type": {"application/xml"}}, mkcolAddressbook)
	if err == nil && resp.Status != http.StatusCreated {
		err = fmt.Errorf("MKCOL %s answered %d: %s", addressbookPath, resp.Status, harness.Clip(string(resp.Body)))
	}
	if err != nil {
		t.Fatalf("making %s's addressbook: %v", davUser, err)
	}
}

// largeCard returns a vCard 3.0 whose photo is largePhotoBytes, in base64
// folded at 75 octets a line, as RFC 2425 has a long line written.
func largeCard() []byte {
	photo := make([]byte, largePhotoBytes)
	for i := range photo {
		photo[i] = byte(i % 251)
	}
	var b bytes.Buffer
	b.WriteString("BEGIN:VCARD\r\nVERSION:3.0\r\nUID:large-1\r\nFN:Large Photo\r\nN:Photo;Large;;;\r\nPHOTO;ENCODING=b;TYPE=JPEG:")
	for line := range slices.Chunk([]byte(base64.StdEncoding.EncodeToString(photo)), 74) {
		b.WriteString("\r\n ")
		b.Write(line)
	}
	b.WriteString("\r\nEND:VCARD\r\n")
	return b.Bytes()
}

// putOverCap puts bodyCap+1 bytes as alice, and reads the answer, with
// length as its Content-Length, or chunked when length is -1. The body is
// streamed, so the suite never holds it.
//
// With a length, the PUT sends Expect: 100-continue, and the body only
// once the server says it will read it. A server that refuses on the
// length alone answers without reading any of the body, and then resets
// a connection still carrying it, so a client already streaming the body
// could lose the answer to the reset. Asked first, the server refuses
// before the body leaves, and one that would read it says so, and gets
// it. Chunked, the server reads up to the cap before it answers, so the
// body is all but sent by then.
func putOverCap(ctx context.Context, s *harness.Serving, length int64) (harness.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, s.Base+overCapPath, io.LimitReader(zeros{}, bodyCap+1))
	if err != nil {
		return harness.Response{}, err
	}
	req.ContentLength = length
	req.Header.Set("Authorization", basicAuth())
	req.Header.Set("Content-Type", "text/vcard")
	client := harness.HostClient()
	if length >= 0 {
		req.Header.Set("Expect", "100-continue")
		client.Transport = &http.Transport{ExpectContinueTimeout: continueWithin, DisableKeepAlives: true}
	}
	resp, err := client.Do(req)
	if err != nil {
		return harness.Response{}, err
	}
	body, err := io.ReadAll(resp.Body)
	if err = errors.Join(err, resp.Body.Close()); err != nil {
		return harness.Response{}, fmt.Errorf("PUT %s: reading the answer: %w", overCapPath, err)
	}
	return harness.Response{Status: resp.StatusCode, Header: resp.Header, Body: body}, nil
}

// zeros reads as an endless run of zero bytes.
type zeros struct{}

func (zeros) Read(p []byte) (int, error) {
	clear(p)
	return len(p), nil
}

// tmpUsed returns how many bytes of /tmp are in use in c, as its own PHP
// reads them.
func tmpUsed(ctx context.Context, c *harness.Container) (int64, error) {
	out, err := harness.PHPIn(ctx, c, `printf('%d', disk_total_space('/tmp') - disk_free_space('/tmp'));`)
	if err != nil {
		return 0, err
	}
	n, err := strconv.ParseInt(strings.TrimSpace(out), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("reading /tmp's use in container %s: %w", c, err)
	}
	return n, nil
}

// tmpUsedNow is tmpUsed, failing t if it cannot read it.
func tmpUsedNow(t *testing.T, c *harness.Container) int64 {
	t.Helper()
	n, err := tmpUsed(t.Context(), c)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// tmpBack checks /tmp in c holds no more than tmpSlack beyond before.
func tmpBack(t *testing.T, c *harness.Container, what string, before int64) {
	t.Helper()
	checks := harness.NewChecks(t)
	after, err := tmpUsed(t.Context(), c)
	if err != nil {
		checks.True(what, false, err.Error())
		return
	}
	checks.True(what, after <= before+tmpSlack, fmt.Sprintf("%d bytes in use before, %d after", before, after))
}
