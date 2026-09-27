# Deploying Doubtfire

The `production` directory is a fail-closed, single-host Docker Compose
deployment for the core Doubtfire application. It runs the web and API services,
MariaDB, Redis/Sidekiq, scheduled work, PDF generation, and JPlag behind HTTPS.

It does not contain credentials, institution settings, TLS private keys, or a
default image release. Those values are deployment-specific and must be supplied
before validation will pass. LTI and Gotenberg are optional integrations with
separate component contracts and are not enabled by this stack.

## Requirements and trust boundary

Use a dedicated Linux host with:

- Docker Engine and Docker Compose v2.33.1 or newer;
- `curl`, OpenSSL, and standard GNU utilities including `timeout`;
- DNS for the production hostname and a trusted TLS certificate;
- an external AAF, SAML, or LDAP identity provider;
- an SMTP service and an operational sender address;
- outbound HTTPS access to the push services used by supported browsers;
- persistent storage for MariaDB, Redis, logs, and student work; and
- monitored, regularly restored backups of the database and student work.

The PDF and JPlag implementation invokes existing helper containers through the
Docker API. The included HAProxy policy allows only ping/version plus
inspect/exec requests for `jplag` and this project's two TexLive containers; all
other Docker API paths and methods are denied. The proxy is reachable only from
the worker network and is never published. Possession of a Docker socket is
still a high-trust boundary, so use a host dedicated to Doubtfire, pin the tested
HAProxy Alpine image, review policy changes, and monitor denials. The API expects
the JPlag container name `jplag`, so run only one production project per daemon.

### SCORM credential-path mitigation

The inherited SCORM content route is
`/api/scorm/:task_def_id/:username/:auth_token/*file_path`. Its `auth_token`
segment is a reusable credential until the corresponding SCORM token expires.
Putting a credential in a URL path can expose it through access and error logs,
browser history, copied links, monitoring and analytics systems, upstream edge
services, and referrer headers.

For this release, the included Nginx proxy suppresses access-log entries for
`/api/scorm/` paths and returns `Referrer-Policy: no-referrer` on those responses.
The rule is applied without a separate location block, so SCORM requests retain
the common API routing, forwarding headers, and timeout. These controls are
mitigation, not closure: they do not remove the credential from browser history,
the API request target, error reporting, an external load balancer, CDN, WAF, or
APM instrumentation. Configure equivalent redaction or suppression on every
component in front of or observing Doubtfire, restrict access to historic logs,
and treat any previously logged SCORM token as exposed until it expires or is
revoked.

The SCORM launch flow must be redesigned so reusable credentials are carried in
a Secure, HttpOnly, appropriately scoped SameSite cookie or an authorisation
header. Where SCORM clients cannot supply either, exchange a single-use,
short-lived launch code for scoped session state and keep usernames and tokens
out of subsequent asset URLs. That application redesign and token migration is
required before this risk can be considered closed.

During production acceptance, use a disposable SCORM test token and confirm its
asset responses include `Referrer-Policy: no-referrer`, no `/api/scorm/` request
appears in the proxy access log, and an ordinary API request is still logged.
Also inspect API, platform-edge, observability, and error-reporting destinations
for the disposable token, then revoke it. Never paste a real SCORM URL into a
ticket, chat, command history, or acceptance record.

## 1. Prepare runtime configuration

From the repository root:

```bash
cd production
cp .env.production.example .env.production
chmod 600 .env.production
```

Replace every `REPLACE_ME` value. The validator rejects placeholder values,
development database authentication, weak/short critical secrets, mutable image
tags, unsafe peer-progress settings, malformed or development VAPID keys,
missing processor limits, unsupported Overseer activation, and runtime files
with unsafe permissions.

Keep each setting in canonical `KEY=value` form. Full-line comments are allowed,
but quoted or escaped values, inline comments, dollar-sign interpolation, and
leading or trailing whitespace are rejected so validation and Compose cannot
interpret the same file differently.

Generate independent random values for database and Rails secrets. For example:

```bash
openssl rand -hex 32
```

Generate a new value for each setting. Existing installations must retain their
Rails signing and Active Record encryption values; changing them without a
planned rotation can invalidate sessions or make encrypted data unreadable.

Set `DF_AUTH_METHOD` to `aaf`, `saml`, or `ldap` and complete that provider's
settings. `database` authentication is deliberately rejected for production.
Set institution, SMTP, and sender values to real operational endpoints. Overseer,
LTI, and Gotenberg are not enabled by this stack. Peer Progress and Web Push are
enabled only through the explicit, fail-closed settings below.

### Sidekiq concurrency contract

Start with `DF_SIDEKIQ_CONCURRENCY=5`. Production validation permits only an
integer from 2 through 5, and Compose injects it only into Sidekiq. Five is the
upper bound of the default Active Record connection pool, which ensures each
worker thread can obtain a database connection without silently overcommitting
the pool. The lower bound keeps one long-running document or similarity job from
being the worker's only available execution path while notification and Peer
Progress jobs are queued.

This range is a release safety bound, not a capacity guarantee. Monitor queue
latency, retry/dead-job counts, database connection saturation, CPU, memory, and
the external PDF/JPlag helpers before lowering concurrency or planning a larger
worker topology. Raising it above 5 requires a coordinated application change,
an explicitly larger Active Record pool, and database-capacity testing; changing
only the environment file is deliberately rejected. Use API and app-worker
images from the same tested release so their concurrency validation, database
pool assumptions, job classes, and cron schedule remain compatible.

### Peer Progress privacy contract

Keep `DF_PPI_MINIMUM_COHORT_SIZE=21`, or raise it if the institution approves a
stricter privacy threshold. Values below 21 are rejected. Keep
`DF_PPI_STALE_AFTER_HOURS=48`, or lower it for a stricter freshness window;
zero, negative, non-integer, and values above 48 are rejected. The API also
fails closed rather than returning peer percentages if either setting is
missing or invalid.

The threshold is the number of remaining peers after the authenticated
student's known contribution has been removed from the exact internal
aggregate. A configured floor of 21 therefore requires at least 22 eligible
students in the target-grade band, including the reader. The same peer-only
threshold protects both the compact completion view and the advanced
task-status distribution. The submitted percentage remains an additive wire
compatibility metric for rolling API/web upgrades; it is not the primary
compact meaning.

The API must fail closed unless the snapshot contains the exact internal
submitted and status counts needed to subtract the reader. It also fails closed
if the reader's project membership or task changed after aggregation, rather
than subtracting a stale known contribution. Advanced percentages are released only when the API's
whole-vector ambiguity check confirms that every displayed peer status still
has multiple feasible raw counts, even if an observer already knows the peer
cohort size. Otherwise the entire distribution is unavailable; never weaken
the cohort setting or bypass that guard to fill the advanced display. Neither
view may expose peer identities, project records, marks, raw cohort size, or raw
submitted/status counts.

Each released status is rounded into its own privacy bucket. The displayed
percentages may therefore total slightly above or below 100%; neither the API
nor the client may renormalise them, because doing so would change the reviewed
privacy mapping and can reveal extra information.

Configuration does not opt units in. `units.peer_progress_enabled` defaults to
false and an authorised convenor must explicitly enable Peer Progress for each
approved unit. Start with a populated test unit, confirm the cohort policy with
the responsible privacy owner, and complete the activation and verification
steps in section 5 before enabling more units. Do not run demo seed tasks against
production.

### Web Push VAPID contract

Generate a new P-256 VAPID pair for this production installation from the exact
accepted API image on a trusted administration host. The production host does
not need Ruby or Bundler. Set `DF_API_IMAGE` to the accepted immutable API digest
and `DF_VAPID_DIR` to a new protected directory; the container has no network,
does not log the keys, and writes them directly to that directory:

```bash
: "${DF_API_IMAGE:?Set the accepted apiserver image@sha256 digest}"
: "${DF_VAPID_DIR:?Set a new absolute protected key directory}"
[[ "${DF_API_IMAGE}" =~ @sha256:[0-9a-f]{64}$ ]]
[[ "${DF_VAPID_DIR}" == /* && ! -e "${DF_VAPID_DIR}" ]]
sudo install -d -m 0700 -o "$(id -u)" -g "$(id -g)" "${DF_VAPID_DIR}"
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --log-driver none \
  --volume "${DF_VAPID_DIR}:/keys" \
  "${DF_API_IMAGE}" \
  bundle exec ruby -e \
  'require "web_push"; key = WebPush.generate_key; {"/keys/public" => key.public_key, "/keys/private" => key.private_key}.each { |path, value| File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(value) } }'
sudo chown "$(id -u):$(id -g)" "${DF_VAPID_DIR}/public" "${DF_VAPID_DIR}/private"
chmod 0600 "${DF_VAPID_DIR}/public" "${DF_VAPID_DIR}/private"
```

Set `DOUBTFIRE_VAPID_PUBLIC_KEY`, `DOUBTFIRE_VAPID_PRIVATE_KEY`, and an explicit
`DOUBTFIRE_VAPID_SUBJECT`. The subject must be an operational `mailto:` address
or HTTPS contact URL. The example values are deliberately non-secret
placeholders and validation will reject them. The checked-in development pair
is also rejected. The private key is supplied only to the API and Sidekiq
containers; transfer it into the approved secret manager using a secure editor
or secret-ingestion mechanism, never by printing it to a terminal. Never put it
in Git, tickets, command arguments, build logs, or browser configuration.
Securely delete the temporary key directory after escrow and deployment are
verified.

Use the [private-key audit runbook](docs/vapid-secret-audit.md) to check the
actual secret against local Git history, original image layers and protected
log exports without printing its value. A source review or a clean current
container filesystem cannot establish that earlier layers and logs are clean.

Store the private key in the institution's secret manager and encrypted recovery
escrow alongside the Rails encryption keys. Preserve it across deployments and
restores. Rotating the pair invalidates every existing browser subscription:
schedule the rotation, deploy both API and Sidekiq with the new pair, notify
users, and require them to enable push again. A database restore without the
matching VAPID private key cannot deliver to its saved subscriptions.

Allow outbound TCP 443 from API and Sidekiq to the endpoint hosts issued by the
supported browsers. The current application allowlist includes
`fcm.googleapis.com`, `android.googleapis.com`,
`updates.push.services.mozilla.com`, subdomains of `push.apple.com`, subdomains
of `push.services.microsoft.com`, and subdomains of `notify.windows.com`. Review
captured subscription endpoint hosts whenever the supported browser matrix
changes; do not assume browser vendors will keep endpoints static.

## 2. Pin tested images

Every image setting must use a fully qualified image name followed by
`@sha256:` and exactly 64 hexadecimal digest characters.

Build the mutually compatible API, app-worker, web, TexLive, and JPlag images
through the revision-locked publisher in `RELEASING.md`; use only the complete
digest manifest it emits after every registry verification succeeds. Resolve
the separately selected proxy, MariaDB, Redis, and HAProxy images to digests
through the institution's approved registry process. Never place the candidate
tag itself in `.env.production`.

Record the tested digest in `.env.production`, including for Nginx, MariaDB,
Redis, and `haproxy:3.2-alpine`. The app-worker image must include the secure
production runtime scripts from the matching Doubtfire API release; older
`pdfgen_entry_point.sh` versions print their environment and must not be used.
The API image must come from the same release and provide the dependency-aware
`/readiness` endpoint used by the Compose and public health checks.

## 3. Prepare host storage and service files

Create the absolute directories configured by `STUDENT_WORK_PATH`,
`DOUBTFIRE_LOG_PATH`, `MARIADB_DATA_PATH`, and `REDIS_DATA_PATH`. Also create
`JPLAG_REPORT_PATH` and `JPLAG_ARCHIVE_REPORT_PATH` beneath the student-work
directory. The JPlag container receives only those two report paths, and the
TexLive containers receive no student-work mount. Keep runtime data outside the
Git checkout and restrict ownership to the deployment operators and container
users that require access.

Set explicit CPU, memory, and PID ceilings for TexLive and JPlag based on host
capacity and measured workload. The supplied example is a conservative starting
point, not a sizing guarantee.

Provide the certificate and unencrypted private key configured by
`TLS_CERTIFICATE_PATH` and `TLS_PRIVATE_KEY_PATH`. The validator confirms that
the certificate matches the key and hostname and will remain valid for at least
30 days. Restrict the private key to its owner:

```bash
chmod 600 /absolute/path/to/private.key
```

Copy the mail helper examples outside the repository and replace every
placeholder:

```bash
sudo install -d -m 0755 /etc/doubtfire
sudo install -m 0644 shared-files/aliases.example /etc/doubtfire/aliases
sudo install -m 0600 shared-files/msmtprc.example /etc/doubtfire/msmtprc
```

Update the two absolute paths in `.env.production`. The Rails SMTP settings and
`msmtprc` should describe the same approved mail service.

Automate certificate renewal. Because the certificate and key are file bind
mounts, recreate only the proxy after a successful renewal so Docker remounts
the replacement files, then verify both public health endpoints:

```bash
./compose.sh up --detach --no-deps --force-recreate --wait --wait-timeout 60 proxy
```

## 4. Validate and deploy

Run the preflight before every deployment:

```bash
./validate.sh
```

Deploy only after it passes:

```bash
./deploy.sh
./verify.sh
```

The default health wait is five minutes. Supply a different bounded value from
1 through 86400 seconds as the second argument when an approved migration needs
longer:

```bash
./deploy.sh .env.production 900
```

The deployment helper validates configuration, pulls the exact image digests,
stages and health-checks the hardened web image, then enters a bounded
maintenance window by stopping public ingress and all application writers before
applying the API migration and worker stack. Before invoking it, the release
owner must confirm the consistent recovery set and migration rehearsal are
current and use database monitoring to clear or explicitly accept long-running
transactions. This order is required because the new web accepts both legacy
query and fragment authentication callbacks, while the hardened API emits
fragments that an older web build cannot consume. The helper waits for declared
health checks and running worker processes, keeps ingress and writers stopped on
a failed rollout, and prints diagnostics. `verify.sh` then runs
the fail-closed post-deploy gates against the same environment file and local
Compose wrapper. A one-shot `migrate` service runs after MariaDB is healthy; API
and worker startup is gated on successful migrations. API readiness checks both
MariaDB and Redis. Only ports 80 and 443 are published. MariaDB, Redis, the
Docker API proxy, and application services remain on private Compose networks.

Both helpers accept an explicit environment file. `verify.sh` also accepts a
bounded per-check timeout:

```bash
./verify.sh .env.production 60
```

It verifies public TLS/proxy readiness, direct API database/Redis readiness,
the web index and PWA control files, pending migrations, a live Sidekiq process
at the configured concurrency, the required peer-progress and notification cron
jobs, and live PPI/VAPID configuration without printing credentials or student
data. A successful exit means only that the automated gates passed; its clearly
labelled manual gates remain mandatory before traffic or a rollback is accepted.

For a release supporting desktop installation, also run the public-asset gate
and installed-browser acceptance matrix in [DESKTOP-PWA.md](DESKTOP-PWA.md).
The standalone gate uses Python 3.9+ and supplements `verify.sh`:

```bash
python3 -B ./verify-pwa.py https://ontrack.example.edu --timeout 30
```

Replace the example with the canonical public origin. This additional gate
checks the web manifest, PNG icons, worker caching and released asset hashes;
a passing result does not install or certify an operating-system app.

`compose.sh` deliberately clears the ambient shell before invoking Compose and
pins the Docker CLI to the local `/var/run/docker.sock`. This prevents exported
variables or a remote Docker context from changing the configuration that was
validated. The production host must expose its local Docker daemon at that
standard socket path.

On the first deployment, keep external ingress blocked with the host firewall or
institutional edge until initialisation and manual identity acceptance are
complete. Initialise Doubtfire's roles, statuses, and initial administrator once:

```bash
./compose.sh exec apiserver bundle exec rake db:init
```

Then use the Rails console to replace the initial administrator's placeholder
profile with the authorised operational identity. Do not enable database
authentication or retain a default password to make first login easier. Complete
the administrator IdP login/logout and the applicable verification gates before
allowing public ingress.

## 5. Verify the deployment

Run the automated gate at minimum:

```bash
./compose.sh ps
./verify.sh
```

Complete every `MANUAL-*` gate printed by `verify.sh`. In particular, exercise a
real login through the configured identity provider, send a notification email,
generate a PDF through Sidekiq/TexLive, and run a permitted JPlag check before
accepting traffic. Confirm that database and Redis ports are not published and
that container logs contain no credentials or private keys.

For Peer Progress, have an authorised convenor enable it in Unit Settings for a
single approved test unit. Enqueue the first aggregation rather than waiting for
the nightly schedule (replace `UNIT_CODE` with the exact production unit code):

```bash
./compose.sh exec apiserver bundle exec rails runner \
  'unit = Unit.find_by!(code: "UNIT_CODE"); abort "Peer Progress is not enabled" unless unit.peer_progress_enabled?; AggregatePeerProgressJob.perform_async(unit.id); puts "Peer Progress aggregation queued"'
```

Wait for Sidekiq to log completion, then verify that the schedule is loaded and
that a fresh snapshot exists without printing student-level data:

```bash
./compose.sh exec sidekiq bundle exec rails runner \
  'abort "Peer Progress schedule missing" unless Sidekiq::Cron::Job.find("aggregate_peer_progress"); puts "Peer Progress schedule loaded"'
./compose.sh exec apiserver bundle exec rails runner \
  'unit = Unit.find_by!(code: "UNIT_CODE"); snapshot = unit.peer_progress_snapshots.order(calculated_at: :desc).first; abort "No Peer Progress snapshot" unless snapshot; abort "Peer Progress exact aggregates are incomplete" if snapshot.submitted_count.nil? || snapshot.status_counts.nil?; abort "Peer Progress snapshot is stale" if snapshot.calculated_at < ENV.fetch("DF_PPI_STALE_AFTER_HOURS").to_i.hours.ago; puts "Fresh Peer Progress snapshot with exact peer-only inputs present"'
```

Sign in as a student in that test unit and inspect the Peer Progress response and
display. Confirm that the indicator appears below the task submission area, the
compact view is the initial task view, and its small advanced control reveals
the quantised canonical status distribution. Exercise representative statuses,
including redo and fix-and-resubmit. Confirm the profile preference is on for a
new student and that switching it off removes peer progress without affecting
submission controls.

For an eligible remaining-peer cohort, the response may contain only approved state fields,
the quantised completed percentage, the additive submitted compatibility
percentage, and (when its independent ambiguity guard passes) the quantised
`status_distribution`. Confirm that a cohort below the configured threshold
(which can never be lower than 21 peers after excluding the reader) suppresses
all peer percentages. Confirm that a legacy snapshot without exact submitted
and status counts, and a snapshot older than the reader's current project/task
context, also fail closed until aggregation refreshes them. Separately
exercise a cohort whose detailed vector is withheld by the vector privacy guard:
the compact view may remain available, but advanced data must fail closed with a
non-sensitive explanation and useful navigation or retry choices. No response
or display may expose names, identifiers, peer project records, marks, raw
cohort size, or raw status counts.

Web Push acceptance requires a real supported browser and cannot be replaced by
Compose health checks. Over HTTPS, sign in and confirm `/ngsw.json` loads and the
authenticated `/api/settings` response reports `pushEnabled: true` with the
configured public key. Use the application's user-gesture control to grant
notification permission and create a subscription. Trigger a known notification
that is processed by Sidekiq, verify it appears with the application in the
background, and verify clicking it opens the intended OnTrack route. Record the
browser, operating system, endpoint host, and result. Repeat on at least one
desktop browser and every mobile/browser combination the institution promises
to support; iOS/iPadOS testing must use an installed Home Screen web app.

Monitor at least:

- external HTTPS and `/healthz` availability;
- container health/restarts and migration failures;
- Sidekiq queue latency, retries, and dead jobs;
- Peer Progress aggregation age and suppressed/error responses;
- scheduled PDF/JPlag job failures;
- Web Push delivery failures, expired subscriptions, and rejected endpoint hosts;
- SMTP delivery failures;
- database/storage capacity and backup age; and
- TLS certificate expiry.

## Backups and restore tests

The receiving institution must set and approve a recovery point objective
(RPO), recovery time objective (RTO), backup frequency, retention, encryption
owner, off-host copy location, and restore-test frequency. Record those values
and the last successful isolated restore in the release change. A backup is not
accepted merely because a file exists.

Back up the MariaDB database and the complete `STUDENT_WORK_PATH` as one labelled
recovery set. For the cleanest consistency boundary, enter maintenance, stop all
application writers, let Sidekiq stop gracefully, capture both components, and
then restart. Run the following as one reviewed Bash block from the `production`
directory. Replace the student-work source with the exact path from the validated
environment file:

```bash
(
  set -Eeuo pipefail
  umask 077

  DF_BACKUP_ROOT=/srv/doubtfire/backups
  DF_STUDENT_WORK_SOURCE=/srv/doubtfire/student-work
  DF_BACKUP_ID="doubtfire-$(date -u +%Y%m%dT%H%M%SZ)"
  DF_BACKUP_PATH="${DF_BACKUP_ROOT}/${DF_BACKUP_ID}"
  DF_BACKUP_OPERATOR_UID="$(id -u)"
  DF_BACKUP_OPERATOR_GID="$(id -g)"
  DF_MAINTENANCE_STARTED=0

  backup_failure() {
    local status="$1"
    trap - ERR INT TERM
    if [[ "${DF_MAINTENANCE_STARTED}" == 1 ]]; then
      timeout --kill-after=10s 120s \
        ./compose.sh stop --timeout 60 proxy apiserver sidekiq pdfgen || true
    fi
    printf 'Backup failed; if maintenance started, application writers remain stopped.\n' >&2
    exit "${status}"
  }
  trap 'backup_failure $?' ERR
  trap 'backup_failure 130' INT
  trap 'backup_failure 143' TERM

  DF_RUNNING_SERVICES="$(./compose.sh ps --status running --services)"
  if grep -Fxq migrate <<< "${DF_RUNNING_SERVICES}"; then
    printf 'Refusing backup while the migration service is running.\n' >&2
    exit 1
  fi
  [[ -d "${DF_STUDENT_WORK_SOURCE}" ]] || {
    printf 'Student-work source is not a directory.\n' >&2
    exit 1
  }

  sudo install -d -m 0700 \
    -o "${DF_BACKUP_OPERATOR_UID}" \
    -g "${DF_BACKUP_OPERATOR_GID}" \
    "${DF_BACKUP_PATH}"

  DF_MAINTENANCE_STARTED=1
  timeout --kill-after=10s 120s \
    ./compose.sh stop --timeout 60 proxy apiserver sidekiq pdfgen
  ./compose.sh exec -T doubtfire-db sh -c \
    'exec mariadb-dump --single-transaction --routines --events \
      --user="$MARIADB_USER" --password="$MARIADB_PASSWORD" "$MARIADB_DATABASE"' \
    > "${DF_BACKUP_PATH}/database.sql"
  sudo tar --acls --xattrs --numeric-owner \
    -C "${DF_STUDENT_WORK_SOURCE}" \
    -cpf "${DF_BACKUP_PATH}/student-work.tar" \
    .
  sudo chown \
    "${DF_BACKUP_OPERATOR_UID}:${DF_BACKUP_OPERATOR_GID}" \
    "${DF_BACKUP_PATH}/student-work.tar"
  chmod 0600 \
    "${DF_BACKUP_PATH}/database.sql" \
    "${DF_BACKUP_PATH}/student-work.tar"

  (
    cd "${DF_BACKUP_PATH}"
    sha256sum database.sql student-work.tar > SHA256SUMS
  )
  ./compose.sh up --detach --wait --wait-timeout 300
  ./verify.sh .env.production 60

  DF_MAINTENANCE_STARTED=0
  trap - ERR INT TERM
)
```

Stopping the writers creates a short outage but avoids a database record being
captured without its corresponding student file. A storage platform may instead
use an application-consistent snapshot mechanism, but document and test its
equivalent quiesce boundary. If any backup command fails, keep traffic stopped,
preserve diagnostics, and do not label the partial set usable.

Encrypt the set, restrict access, validate checksums after transfer, and keep an
off-host copy. Record the matching secret-manager/escrow versions for all Rails
signing and Active Record encryption keys, database credentials, VAPID private
key, TLS material, and external-service configuration. Do not place those
secrets inside the Git repository or an unencrypted backup manifest.

Redis/Sidekiq is not part of the authoritative recovery set. Restoring an old
queue can replay non-idempotent exports or notifications, while discarding it
can lose jobs accepted after the database recovery point. The maintenance
boundary minimises that window. The incident/recovery owner must record the
queue-loss decision, inspect database state, let cron recreate scheduled work,
queue a fresh PPI aggregation for approved units, and have users request lost
one-off exports/PDFs again. Never bulk replay notification jobs without a
product/privacy review because recipients may receive duplicates.

### Isolated restore rehearsal

Restore only onto an isolated host with empty data paths, blocked production
email/push egress, a test hostname/certificate, the exact release manifest, and
the matching escrowed Rails/encryption/VAPID material. Never test by overwriting
the live paths.

1. Verify the encrypted set and its checksums before extraction. Keep the
   restore path explicit rather than relying on a later working directory:

   ```bash
   : "${DF_RESTORE_DIR:?Set the absolute restored backup directory}"
   [[ "${DF_RESTORE_DIR}" == /* ]]
   cd "${DF_RESTORE_DIR}"
   sha256sum --check SHA256SUMS
   ```

2. Restore `student-work.tar` to the empty `STUDENT_WORK_PATH`, preserving
   numeric ownership, ACLs and extended attributes. Set the exact validated
   target path; the block refuses a non-empty target:

   ```bash
   (
     set -Eeuo pipefail
     : "${DF_RESTORE_DIR:?Set the absolute restored backup directory}"
     [[ "${DF_RESTORE_DIR}" == /* ]]
     DF_STUDENT_WORK_TARGET=/srv/doubtfire/student-work
     sudo install -d -m 0750 "${DF_STUDENT_WORK_TARGET}"
     [[ -z "$(sudo find "${DF_STUDENT_WORK_TARGET}" -mindepth 1 -print -quit)" ]] || {
       printf 'Student-work restore target is not empty.\n' >&2
       exit 1
     }
     sudo tar --acls --xattrs --numeric-owner \
       -C "${DF_STUDENT_WORK_TARGET}" \
       -xpf "${DF_RESTORE_DIR}/student-work.tar"
   )
   ```

   Confirm the configured JPlag report/archive subdirectories are present and
   container-readable.

3. From the release's `production` directory, validate the isolated
   `.env.production`, start only an empty MariaDB and Redis, wait for both to be
   healthy, prove the target schema has no tables, then import the dump. Set
   `DF_RESTORE_DIR` to the same absolute path used in step 1:

   ```bash
   DF_PRODUCTION_DIR="$(pwd)"
   : "${DF_RESTORE_DIR:?Set the absolute restored backup directory}"
   [[ "${DF_RESTORE_DIR}" == /* ]]
   test -x "${DF_PRODUCTION_DIR}/validate.sh"
   ./validate.sh
   ./compose.sh up --detach --wait --wait-timeout 120 \
     doubtfire-db redis-sidekiq
   ./compose.sh exec -T doubtfire-db sh -ec \
     'count="$(mariadb --batch --skip-column-names \
       --user="$MARIADB_USER" --password="$MARIADB_PASSWORD" \
       --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"$MARIADB_DATABASE\"")"; \
      test "$count" = 0'
   ./compose.sh exec -T doubtfire-db sh -c \
     'exec mariadb --user="$MARIADB_USER" \
       --password="$MARIADB_PASSWORD" "$MARIADB_DATABASE"' \
     < "${DF_RESTORE_DIR}/database.sql"
   ```

4. Run `./deploy.sh` and `./verify.sh`. Confirm the restored migration version,
   representative users/units/submissions, recent notification state, fresh PPI
   regeneration, and several sampled student files by application download and
   checksum. Exercise identity using an approved test integration and keep real
   SMTP/push delivery blocked.

5. Record start/finish time, achieved RPO/RTO, manifest, backup ID, checksums,
   secret escrow versions, row/file sampling, queue-loss decision, verifier
   output, discrepancies and named acceptance. Destroy the isolated copy under
   the institution's data-handling policy.

Rehearse at the receiving team's approved cadence and before a migration whose
rollback depends on restore. A failed or stale rehearsal blocks release.

## Upgrades and rollback

Before an upgrade:

1. confirm the backup and restore test are current;
2. record the running image digests and Git revision;
3. review API migrations for backward compatibility;
4. update only the tested digests in `.env.production`; and
5. run `./validate.sh`, `./deploy.sh`, and `./verify.sh`, then complete the
   printed manual gates.

Afterward, repeat the verification checks and inspect worker queues and logs.
For an application rollback, enter a maintenance/drain window and restore the
previous image digests. Roll back the API before the web so the hardened web can
continue to accept either authentication callback form; do not expose an old
web image to a still-hardened API. Use the verifier and acceptance procedure
retained with the previous release manifest and repeat every applicable
release-independent manual gate before accepting the rollback. The current
`verify.sh` intentionally requires this release's exact schema, cron jobs and
PPI/VAPID contract; do not weaken it or claim its expected failure against older
images is a valid acceptance result. If the previous release has no compatible
automated verifier, record and complete a named `MANUAL-ROLLBACK-CONTRACT` gate
covering public and dependency readiness, migrations, queues, identity,
messaging, data integrity, ports and credential-safe logs. If a migration is not
backward-compatible, image rollback alone is unsafe; follow the migration's
documented rollback or restore the matching database and student-work recovery
set in a controlled outage, then run the same applicable automated and manual
acceptance gates.

`deploy.sh` is a forward-only helper and must not be used for rollback because it
stages web first. Before release, the previous manifest must contain the exact
previous deploy checkout, environment/digest manifest, bounded API/app-worker-
before-web commands, migration decision, failure diagnostics and version-matched
acceptance procedure, all proven in rehearsal. Absence of that executable
rollback record is a release blocker rather than permission to improvise during
an incident.

Never run `./compose.sh down --volumes` against production. The temporary
TexLive and JPlag volumes are disposable, but the host paths configured for the
database, Redis, logs, and student work are production data.

## CI-only configuration rendering

`DOUBTFIRE_CONFIG_ONLY=1 ./validate.sh /path/to/fixture.env` skips only the live
Docker socket accessibility check. It exists for isolated CI validation and
must not be used by `deploy.sh` or as a production preflight substitute.
