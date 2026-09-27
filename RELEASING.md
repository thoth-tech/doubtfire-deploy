# Publishing an OnTrack production release

This procedure turns the exact API and web gitlinks in this repository into
immutable production images. It complements `HANDOVER.md` (release ownership
and acceptance), `MIGRATING.md` (schema dossier), and `DEPLOYING.md` (host
configuration, rollout, verification and recovery).

The historical root `release.sh` only creates source tags. It does not build,
scan, attest, sign or deploy the production API, app-worker, web, TexLive and
JPlag artifacts. Do not use it as evidence that a deployable release exists.

## 1. Lock and approve source

1. Complete human review and required checks on the API, web and deploy pull
   requests. Keep the umbrella branches draft until their focused review gates
   are satisfied; an integration branch does not bypass repository rules.
2. Pin `doubtfire-api` and `doubtfire-web` to the accepted commits and update
   their revision rows in `HANDOVER.md` in the same deploy commit. The deploy
   commit cannot embed its own hash; its protected signed tag is resolved and
   recorded in the external release manifest after that commit exists.
3. From a fresh recursive clone, prove both gitlinks and the nested web JPlag
   submodule initialise, then run the automated API/web/deploy checks and the
   isolated all-features demo.
4. Create protected signed API and web release refs at the pinned component
   commits, then tag the accepted deploy commit under the same retention policy.
   Record all three refs and resolved Git revisions in the change record. Prove
   a fresh recursive clone can fetch them through this repository's configured
   submodule URLs before publishing.

The API and app-worker images must always be built from the same API commit.
The web image must be built from the pinned web commit. Never rebuild a release
tag from a different checkout and never promote a mutable tag by name alone.

## 2. Publish attested application images

Use an institution-controlled OCI registry with retention/deletion protection.
Authenticate Docker, create a clean recursive clone at the accepted deploy
commit, and run:

```bash
(
  set -Eeuo pipefail
  set -o noclobber
  umask 077
  : "${DF_RELEASE_VERSION:?Set the release-owner-approved version before publishing}"
  : "${DF_RELEASE_EVIDENCE_DIR:?Set an absolute protected directory outside the Git checkout}"
  [[ "${DF_RELEASE_EVIDENCE_DIR}" == /* ]]
  test -d "${DF_RELEASE_EVIDENCE_DIR}"
  PUBLISH_RELEASE_CONFIRM=1 \
    production/publish-release.sh \
    registry.example.edu/ontrack \
    "${DF_RELEASE_VERSION}" \
    linux/amd64,linux/arm64 \
    > "${DF_RELEASE_EVIDENCE_DIR}/release-application-digests.txt"
)
```

Choose the version under the release owner's normal versioning policy and record
it in the manifest. Do not copy an example version: `CHANGELOG.md` already
contains 11.0.1, and publishing an older-looking version would make promotion
and rollback evidence ambiguous. The publisher rejects mutable names, `.x`
series labels and common placeholder text, but the registry must still enforce
tag immutability and retention. Keep the evidence output outside the clean
checkout: shell redirection creates its target before the publisher checks Git,
so writing it into the repository would correctly make publication fail. A
nonzero publisher exit leaves incomplete evidence that must be quarantined and
must never be accepted as a release manifest.

For a PWA recovery release rebuilt from prior web source, add `--no-cache-web` to
the publisher invocation. This bypasses Docker's build cache for the web image
so Angular generates a fresh service-worker manifest; the other four images
retain their normal cache behavior. A new tag or version label alone does not
invalidate the cached Angular build. Use a distinct immutable recovery version
and follow [desktop client recovery](DESKTOP-PWA.md#rollback-and-recovery),
including acceptance in a client still running the failed release.

The publisher refuses dirty or mismatched component worktrees, then creates
temporary build contexts only from files tracked by the pinned Git commits. It
populates nested web assets from the exact nested gitlink, so ignored or
untracked host files cannot enter an image through `COPY .`. It builds:

| Manifest key | Source |
| --- | --- |
| `DOUBTFIRE_API_IMAGE` | `doubtfire-api/deployApi.Dockerfile` |
| `DOUBTFIRE_APP_IMAGE` | `doubtfire-api/deployAppSvr.Dockerfile` |
| `DOUBTFIRE_WEB_IMAGE` | `doubtfire-web/deploy.Dockerfile` |
| `TEXLIVE_IMAGE` | `doubtfire-api/texlive.Dockerfile` |
| `JPLAG_IMAGE` | `doubtfire-api/jplag.Dockerfile` |

Every build is multi-platform, labels each image with its verified component Git
revision and release version, pushes a manifest, and requests BuildKit SBOM and
maximum provenance attestations. The stdout file contains Git revisions and
`image@sha256:...` references; protect it as change evidence. The script never
reads or writes `.env.production` and does not print registry credentials. Tags
are only publication labels and may be mutable unless the registry enforces
immutability; the digest is the release identity.

## 3. Supply-chain acceptance

Before an image digest can enter production configuration:

- verify its registry provenance/SBOM attestations identify the expected Git
  revision, Dockerfile, build platform and builder identity;
- scan the immutable digest with the institution-approved container and licence
  scanners, triage every critical/high result, and record any time-bounded risk
  acceptance with an owner and expiry;
- sign the digest using the institution-approved keyless or protected-key
  identity, verify the signature under policy, and retain transparency/audit
  evidence;
- confirm API/app-worker labels and bundled source identify the same API commit,
  the web JPlag assets are populated, and no secrets appear in layers, history,
  SBOM or build logs; and
- retain the exact digest, attestations, signature and scan report for rollback,
  rather than relying on a tag that can move.

The publisher does not choose the Nginx proxy, MariaDB, Redis or HAProxy images.
Select separately reviewed versions, resolve their multi-platform digests, scan
and sign/verify them under the same policy, and record them in the release
manifest. Refresh a pinned base or runtime image only as a reviewed dependency
change followed by a complete rebuild and acceptance cycle.

## 4. Complete the manifest and stage

Copy accepted immutable references into a protected `.env.production` created
from `production/.env.production.example`. Complete the release-manifest fields
in `HANDOVER.md`, including the previous release, migration target, recovery
set, secret-escrow versions, scans, attestations, signatures, manual owners and
rollback decision.

Run in a production-equivalent staging environment:

```bash
cd production
./validate.sh
./deploy.sh
./verify.sh
```

Complete the real IdP, SMTP, PPI, push-device, PDF/JPlag, SCORM and recovery
gates without production student data. The forward helper stages compatible web
before API. If LTI is separately enabled, its redirector must be verified not to
place `ltik`, auth tokens or usernames in a query URL.

## 5. Production promotion

Promote by digest, not by rebuilding. Re-run `validate.sh` against the exact
production environment file, confirm the consistent backup/restore evidence and
migration rehearsal are current, then follow `DEPLOYING.md`. Save verifier and
manual-gate evidence and obtain the named release owner's go/no-go.

A release is complete only when monitoring and on-call routing are active, the
final manifest is immutable, and both forward and rollback references are
retained. A failed gate stops promotion; do not relabel or retag an unaccepted
digest to work around it.
