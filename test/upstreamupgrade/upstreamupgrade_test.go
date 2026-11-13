// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

// Package upstreamupgrade tests test/upstream-upgrade-api.sh, the guard the
// Containerfile's fetch stage runs over the unpacked Baikal release. The
// guard runs against copies of testdata/ok, a stand-in for that release
// holding every member baikal-bootstrap's upgradeDatabase() reaches, each
// changed the way a release might change it, and every way the guard can
// fail is seen failing.
package upstreamupgrade

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// guard is the script under test, from this package's directory.
const guard = "../upstream-upgrade-api.sh"

// ok is the fixture every case starts from: a tree the guard passes.
const ok = "testdata/ok"

// The two files of the release the guard reads, relative to its root.
const (
	upgradeFile = "Core/Frameworks/BaikalAdmin/Controller/Install/VersionUpgrade.php"
	sqliteFile  = "Core/Frameworks/Flake/Core/Database/Sqlite.php"
)

// The member each ERROR line names, one for each the guard looks for.
const (
	class       = upgradeFile + " no longer has class VersionUpgrade extends"
	upgrade     = upgradeFile + " no longer has protected function upgrade("
	success     = upgradeFile + " no longer has protected $aSuccess"
	connection  = upgradeFile + " no longer has its connection from $GLOBALS['DB']->getPDO()"
	constructor = sqliteFile + " no longer has function __construct($sDbPath)"
)

// edit rewrites one file of the tree. from is a regular expression that
// must match exactly once, so that a fixture which drifts fails the test
// rather than passing it for the wrong reason.
type edit struct {
	file, from, to string
}

// result is how a run of the guard ended.
type result struct {
	code           int
	stdout, stderr string
}

func TestUpstreamUpgradeAPI(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		// remove deletes paths from the tree, and edits rewrite its files.
		remove []string
		edits  []edit
		// want holds one string per ERROR line the guard must print, each
		// naming the file and the member at fault. Empty means it passes.
		want []string
	}{
		{name: "ok"},
		{
			// Reported once, as missing, and not again for each member
			// it no longer has
			name:   "missing-upgrade",
			remove: []string{upgradeFile},
			want:   []string{upgradeFile + " is missing"},
		},
		{
			name:   "missing-sqlite",
			remove: []string{sqliteFile},
			want:   []string{sqliteFile + " is missing"},
		},
		{
			name:  "class-reparented",
			edits: []edit{{upgradeFile, `extends \\Flake\\Core\\Controller`, `extends \Flake\Core\Model`}},
			want:  []string{class},
		},
		{
			// The bootstrap's subclass calls it, which private forbids
			name:  "upgrade-made-private",
			edits: []edit{{upgradeFile, `protected function upgrade`, "private function upgrade"}},
			want:  []string{upgrade},
		},
		{
			name:  "upgrade-arguments-changed",
			edits: []edit{{upgradeFile, `, \$sVersionTo\)`, ", $$sVersionTo, $$bDryRun)"}},
			want:  []string{upgrade},
		},
		{
			name:  "success-list-typed",
			edits: []edit{{upgradeFile, `protected \$aSuccess`, "protected array $$aSuccess"}},
			want:  []string{success},
		},
		{
			name:  "connection-moved",
			edits: []edit{{upgradeFile, `\$GLOBALS\['DB'\]->getPDO\(\)`, "$$this->db->getPDO()"}},
			want:  []string{connection},
		},
		{
			name:  "constructor-changed",
			edits: []edit{{sqliteFile, `__construct\(\$sDbPath\)`, "__construct(string $$sDbPath)"}},
			want:  []string{constructor},
		},
		{
			// Every change is reported, not only the first
			name: "two-changed",
			edits: []edit{
				{upgradeFile, `protected \$aSuccess`, "public $$aSuccess"},
				{sqliteFile, `__construct\(\$sDbPath\)`, "__construct($$path)"},
			},
			want: []string{success, constructor},
		},
		{
			// Both files there and holding none of it: one ERROR line for
			// each member the guard looks for, so a member added to it
			// without a case here fails this one
			name:  "every-member-gone",
			edits: []edit{{upgradeFile, `(?s)namespace.*`, ""}, {sqliteFile, `(?s)namespace.*`, ""}},
			want:  []string{class, upgrade, success, connection, constructor},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			tree := copyOK(t)
			for _, path := range tt.remove {
				remove(t, filepath.Join(tree, path))
			}
			for _, e := range tt.edits {
				rewrite(t, tree, e)
			}
			check(t, run(t, tree), tt.want)
		})
	}
}

// TestUsage checks the guard refuses a command line that names no tree,
// rather than reporting every member missing from a tree that is not there.
func TestUsage(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		args []string
	}{
		{name: "no-tree"},
		{name: "two-trees", args: []string{ok, ok}},
		{name: "not-a-directory", args: []string{filepath.Join(ok, upgradeFile)}},
		{name: "absent", args: []string{filepath.Join(ok, "absent")}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			r := run(t, tt.args...)
			if r.code != 2 {
				t.Errorf("exit %d, want 2; stderr:\n%s", r.code, r.stderr)
			}
			if !strings.HasPrefix(r.stderr, "usage: ") || strings.Count(r.stderr, "\n") != 1 {
				t.Errorf("stderr is %q, want one usage line", r.stderr)
			}
		})
	}
}

// copyOK copies the ok tree somewhere the test may change it.
func copyOK(t *testing.T) string {
	t.Helper()

	tree := t.TempDir()
	if err := os.CopyFS(tree, os.DirFS(ok)); err != nil {
		t.Fatal(err)
	}
	return tree
}

// rewrite applies e to its file in tree.
func rewrite(t *testing.T, tree string, e edit) {
	t.Helper()

	root, err := os.OpenRoot(tree)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = root.Close() }()
	data, err := root.ReadFile(e.file)
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(e.from)
	if n := len(re.FindAllIndex(data, -1)); n != 1 {
		t.Fatalf("edit %q matches %s %d times, want once", e.from, e.file, n)
	}
	if err := root.WriteFile(e.file, re.ReplaceAll(data, []byte(e.to)), 0o600); err != nil {
		t.Fatal(err)
	}
}

func remove(t *testing.T, path string) {
	t.Helper()

	if _, err := os.Lstat(path); err != nil {
		t.Fatalf("the fixture has nothing to remove: %v", err)
	}
	if err := os.RemoveAll(path); err != nil {
		t.Fatal(err)
	}
}

// run runs the guard with args, and nothing of the host's environment but
// its PATH.
func run(t *testing.T, args ...string) result {
	t.Helper()

	cmd := exec.CommandContext(t.Context(), guard, args...) //nolint:gosec // G204: the guard is this repository's own script, run on trees the test made
	cmd.Env = []string{"PATH=" + os.Getenv("PATH")}
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		if _, ok := errors.AsType[*exec.ExitError](err); !ok {
			t.Fatalf("%s: %v", guard, err)
		}
	}
	return result{cmd.ProcessState.ExitCode(), stdout.String(), stderr.String()}
}

// check fails t unless r passed, saying so, when want is empty, or else
// failed with exactly one ERROR line for each string in want, containing
// it.
func check(t *testing.T, r result, want []string) {
	t.Helper()

	if len(want) == 0 {
		if r.code != 0 || r.stderr != "" || !strings.HasPrefix(r.stdout, "every member the upgrade relies on is in ") {
			t.Fatalf("exit %d, want 0 with the all-present line and nothing on stderr; stdout:\n%s\nstderr:\n%s", r.code, r.stdout, r.stderr)
		}
		return
	}
	if r.code != 1 {
		t.Fatalf("exit %d, want 1 with ERROR lines naming %q; stdout:\n%s\nstderr:\n%s", r.code, want, r.stdout, r.stderr)
	}
	lines := errorLines(r.stderr)
	if len(lines) != len(want) {
		t.Errorf("%d ERROR lines, want %d naming %q; stderr:\n%s", len(lines), len(want), want, r.stderr)
	}
	for _, w := range want {
		if !slices.ContainsFunc(lines, func(line string) bool { return strings.Contains(line, w) }) {
			t.Errorf("no ERROR line contains %q; stderr:\n%s", w, r.stderr)
		}
	}
}

// errorLines returns the lines of stderr that report a failure.
func errorLines(stderr string) []string {
	var lines []string
	for line := range strings.Lines(stderr) {
		if strings.HasPrefix(line, "ERROR: ") {
			lines = append(lines, line)
		}
	}
	return lines
}
