#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>
set -euo pipefail

LAYOUT="${1:?OCI layout of the image to scan}"
REPORT="${2:?path to write its report to}"
PUBLISHED="${3:?published image to compare it with}"
BASELINE="${4:?path to write the report on the published image to}"
SARIF="${5:?path to write the SARIF for code scanning to}"

# A new advisory against something the published image already ships is
# not one a release can make worse. Blocking on it protects nobody and holds
# back whatever else the release fixes, so only a finding the published
# image lacks fails the scan. The rest are advisories: printed here, written
# to the run's summary page and, from main, uploaded to code scanning.
SCAN=(--vex baikal.openvex.json --severity "HIGH,CRITICAL" --format json)

# A clean report from a scan that saw no packages means it never looked.
has_packages() {
    jq -e '(([.Results[]? | .Packages // [] | length] | add) // 0) > 0' "${1}" >/dev/null \
        || { echo "no packages in ${2}: the scan found nothing to scan, not nothing wrong" >&2; exit 1; }
}

trivy image --input "${LAYOUT}" "${SCAN[@]}" --output "${REPORT}"
has_packages "${REPORT}" "${LAYOUT}"
trivy convert --format sarif --output "${SARIF}" "${REPORT}"

arch=$(jq -er '.Metadata.ImageConfig.architecture' "${REPORT}")

# --image-src remote, or a stale copy in the local engine stands in for what
# is published. --skip-db-update, so both reports come from one database: a
# finding only a newer database knows about would otherwise read as new.
if trivy image --image-src remote --platform "linux/${arch}" --skip-db-update \
        "${SCAN[@]}" --output "${BASELINE}" "${PUBLISHED}" 2>"${BASELINE}.log"; then
    has_packages "${BASELINE}" "${PUBLISHED}"
    against=$(jq -r '.Metadata.RepoDigests[0] // .ArtifactName' "${BASELINE}")
elif grep -qE ': (MANIFEST_UNKNOWN|NAME_UNKNOWN|DENIED): ' "${BASELINE}.log"; then
    # ghcr.io answers DENIED for a repository that does not exist. With
    # nothing published, nothing is already shipped: every finding is new.
    echo '{}' >"${BASELINE}"
    against="nothing, because the registry has no ${PUBLISHED}"
else
    cat "${BASELINE}.log" >&2
    echo "could not scan ${PUBLISHED}, so no finding can be told apart from one already published" >&2
    exit 1
fi

findings() {
    jq -c '[.Results[]? | . as $result | .Vulnerabilities[]? | {
        id: .VulnerabilityID, pkg: .PkgName, version: .InstalledVersion,
        fixed: (.FixedVersion // ""), severity: .Severity, url: (.PrimaryURL // ""),
        where: (if $result.Class == "os-pkgs" then "\($result.Type) package" else $result.Target end)
    }]' "${1}"
}

candidate=$(findings "${REPORT}")
published=$(findings "${BASELINE}")

# Same vulnerability in the same package, at any version: a bump from one
# affected version to another leaves the image no worse than what is out.
split=$(jq -n --argjson candidate "${candidate}" --argjson published "${published}" '
    ($published | map({id, pkg})) as $known
    | {new: [$candidate[] | select({id, pkg} as $key | $known | any(. == $key) | not)],
       old: [$candidate[] | select({id, pkg} as $key | $known | any(. == $key))]}')

new=$(jq '.new | length' <<<"${split}")
old=$(jq '.old | length' <<<"${split}")

jq -r --arg against "${against}" '
    def line: "  \(.id) \(.severity) \(.pkg) \(.version)"
        + (if .fixed == "" then ", no fix" else ", fixed in \(.fixed)" end) + ", \(.where)";
    "compared with \($against)",
    "\(.new | length) new, so blocking:", (.new[] | line),
    "\(.old | length) already published, so advisory:", (.old[] | line)' <<<"${split}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    jq -r --arg arch "${arch}" --arg against "${against}" '
        def cell: tostring | gsub("[|]"; "\\|") | gsub("\n"; " ");
        def id: if .url == "" then .id else "[\(.id)](\(.url))" end;
        def table:
            if length == 0 then "None."
            else "| Vulnerability | Severity | Package | Installed | Fixed in | Where |",
                 "|---|---|---|---|---|---|",
                 (.[] | "| \(id | cell) | \(.severity | cell) | `\(.pkg | cell)` | \(.version | cell) | \(if .fixed == "" then "no fix" else .fixed | cell end) | \(.where | cell) |")
            end;
        "### Vulnerability scan, \($arch)", "",
        "Compared with `\($against)`.", "",
        "**New, so blocking: \(.new | length)**", "", (.new | table), "",
        "**Already published, so advisory: \(.old | length)**", "", (.old | table), ""
    ' <<<"${split}" >>"${GITHUB_STEP_SUMMARY}"
fi

if (( new > 0 )); then
    echo "${new} finding(s) the published image does not have. Move what carries them, or argue reachability in baikal.openvex.json." >&2
    exit 1
fi
echo "nothing new against what is published (${old} advisory)"
