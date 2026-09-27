# Finish the VAPID private-key audit (NPR-S03)

The source controls and rotation procedure do not establish that the actual
production private key is absent from historical commits, image layers and
logs. The release owner can complete that check without sharing the key or
dumping container environments. No staging URL or test account is needed.

## What the owner needs

Ask the release owner or operator with secret-manager, registry and log access
for these inputs. Keep the secret itself inside that operator's environment.

1. The **production VAPID private-key version identifier** and read access to
   that version in the approved secret manager. Audit older versions too if
   the ticket covers their use. A development key is not evidence about
   production.
2. The **exact API and Sidekiq image IDs/digests** that ran with that version,
   including retained releases in the audit period. Read only the image ID
   from a running container with `docker inspect --format '{{.Image}}'
   CONTAINER`; do not dump its environment or full inspection output. Pull
   the identified images onto the trusted audit host if they are not local.
3. Full local clones of **api, web and deploy**, with the relevant branches,
   tags and PR refs fetched. The tool refuses shallow clones. Submodules are
   separate repositories; supply each explicitly. Remote-only or pruned
   history cannot be certified from an incomplete local clone.
4. Protected exports of **API, Sidekiq, reverse-proxy and build/CI logs** for
   that secret version's lifetime, including retained/rotated logs. Supply
   each file with `--file`; gzip exports are supported. Missing retention
   periods must be recorded as unknown, not passed.

## Run on the trusted audit host

Use Python 3 and Git. Docker is needed only for `--image`. Export the selected
key directly from the existing secret manager to a new owner-only file outside
the repositories. Use the manager's protected file/export facility; do not put
the value in a command argument, shell history, environment dump, screenshot,
chat, ticket, or build argument. The file must be owned by the invoking user,
have no group/other permissions (for example `0600`), and must not be a symlink.

Set the following variables to **paths or non-secret image references**:

```sh
umask 077
: "${VAPID_AUDIT_KEY_FILE:?Protected key-file path}"
: "${VAPID_AUDIT_API_IMAGE:?Exact API image ID or digest}"
: "${VAPID_AUDIT_WORKER_IMAGE:?Exact Sidekiq image ID or digest}"
: "${VAPID_AUDIT_API_LOG:?Protected API log export path}"
: "${VAPID_AUDIT_WORKER_LOG:?Protected Sidekiq log export path}"
: "${VAPID_AUDIT_PROXY_LOG:?Protected reverse-proxy log export path}"
: "${VAPID_AUDIT_BUILD_LOG:?Protected build log export path}"
: "${VAPID_AUDIT_REPORT:?New protected report path outside Git}"

python3 -B tools/audit-vapid-secret.py \
  --key-file "$VAPID_AUDIT_KEY_FILE" \
  --repo ../doubtfire-api --repo ../doubtfire-web --repo . \
  --image "$VAPID_AUDIT_API_IMAGE" --image "$VAPID_AUDIT_WORKER_IMAGE" \
  --file "$VAPID_AUDIT_API_LOG" --file "$VAPID_AUDIT_WORKER_LOG" \
  --file "$VAPID_AUDIT_PROXY_LOG" --file "$VAPID_AUDIT_BUILD_LOG" \
  > "$VAPID_AUDIT_REPORT"
audit_result=$?
printf 'VAPID audit exit status: %s\n' "$audit_result"
```

Alternatively, pipe the secret manager's raw value output directly to
`--key-stdin`. Interactive terminal input is rejected. Existing protected
`docker image save` archives can be supplied with repeated `--image-archive`
instead of invoking Docker. Never use `docker export`: it drops image history
and deleted layers, so it cannot establish this requirement.

The tool emits JSON with match locations/counts, image identities, scanned
counts and completeness for the selected inputs. It does not print matching
content, a key fingerprint or key values. It suppresses subprocess/parser
diagnostics and redacts secret-bearing paths. For a Git object finding, locate
its commits without displaying file contents:

```sh
git -C REPOSITORY log --all --find-object=OBJECT_ID --format='%H %cI'
```

## Interpret and record the result

| Exit | Meaning | Required action |
| --- | --- | --- |
| `0` | No matches in all selected inputs | Verify the input inventory and retention coverage, then record the owner, UTC date, secret-manager version ID, Git refs, resolved image IDs, log periods, scanner commit and protected report location. |
| `1` | Matches found | Treat the listed locations as exposure evidence. Follow the existing [VAPID rotation procedure](../DEPLOYING.md#web-push-vapid-contract) and API delivery-operations runbook with the release owner. This tool does not rotate keys, delete subscriptions or rewrite history. |
| `2` | Invalid input or incomplete scan | Resolve missing images/files, permissions, archive format or shallow history and rerun. Even zero matches is not a pass when inputs are incomplete. |

Inspect the JSON exit result after completion. If the process is interrupted,
no successful audit exists. Keep reports and exported logs under the operator's
normal protected evidence/retention policy; do not commit them. Remove the
temporary key export using the secret manager's approved local-file handling
procedure after the audit. A copied key export must never become a build input.

## Coverage and limits

- Git scanning reads **every locally available object**, including blobs for
  deleted files, commit/tag messages and unreachable objects. It does not run
  checkout filters or write repository files. LFS content and external
  submodule objects need separate explicit inputs.
- Docker scanning resolves a local tag to an immutable image ID before saving
  it, scans image configuration/history and **each original layer separately**,
  and never unpacks paths to the host. A later whiteout/deletion does not hide
  an earlier leaked file. Gzip-compressed layers are supported. The temporary
  save archive stays in a private directory and is removed after scanning.
- Matching covers the literal base64url private key, padded/standard Base64,
  raw 32-byte scalar, hexadecimal scalar and Base64-encoded text. This is an
  exact-key audit, not a general secret detector. Arbitrary encrypted files,
  split/obfuscated values or nested compressed payloads are not decoded.
- Zero matches says nothing about unprovided production keys, remote logs,
  unavailable image releases, expired log periods or copies outside these
  inputs. Repository fixtures prove the scanner works; they are not production
  attestation.

The current repository contract supplies `DOUBTFIRE_VAPID_PRIVATE_KEY` only in
API/Sidekiq runtime configuration. Production example env values are
placeholders. API `.dockerignore` excludes local env files, credentials, key
files and logs, and release publishing creates contexts from Git archives.
API PR [#174](https://github.com/ontrack-features-t2-2026/doubtfire-api/pull/174)
adds production paired-key validation, filtered private-key parameters and the
rotation procedure. A matching private key remains necessary at runtime; its
presence in the running process environment is not an image-layer finding.
