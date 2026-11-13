// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

package acceptance

import (
	"fmt"
	"net/http"
	"testing"

	"github.com/divbast/ci/harness"
)

// TestPHPSettings checks the two settings php/baikal.ini adds to keep PHP
// to itself: no PHP in the image can open a URL stream, and no response
// names PHP and its version.
func TestPHPSettings(t *testing.T) {
	t.Parallel()
	e, image := underTest(t)
	s := serve(t, e, userSpec(image, newVolume(t, e)))

	harness.RunRecords(t, s.Probe, "assert-ini")

	// /dav.php's 401 is sabre/dav's, so PHP wrote the response, and would
	// have added the header to it
	resp, err := s.Get(t.Context(), "/dav.php", nil)
	harness.Answers(t, "GET /dav.php, which PHP answers", http.StatusUnauthorized, resp, err)
	if err == nil {
		powered := resp.Header.Values("X-Powered-By")
		harness.NewChecks(t).True("responses on :8080 do not name PHP and its version", len(powered) == 0,
			fmt.Sprintf("X-Powered-By: %q", powered))
	}
}
