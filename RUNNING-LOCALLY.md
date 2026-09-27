# Running OnTrack locally (web and api)

How to run OnTrack on your computer with Docker. It also lists the problems we hit and how
to fix them.

## What runs

- doubtfire-api: the backend (Rails). Host port 3200, container port 3000.
- doubtfire-sidekiq: the background worker for queued notification email. See below.
- doubtfire-web: the frontend (Angular). Host port 4400, container port 4200.
- Mailpit: catches every email the app sends. Web inbox on host port 8225.
- A database (MariaDB) and Redis. Docker starts these for you.

## Before you start

- Install Docker Desktop and start it.
- Set your git remotes. `origin` is the team org, `upstream` is thoth-tech.
- Do not use the `development` branch. It is old and frozen.
- Do not install Ruby or Node. They run inside the Docker images. The api needs Ruby 3.4.
  The web needs Node 22.22.3 or newer.
- Do not run `rails`, `rubocop`, or `bundle` on your own computer. Your Mac has old Ruby
  (2.6). Run those inside the container instead.

## Clone all three repos side by side

This is the most common reason the build fails.

Docker builds the api and web containers from folders it expects to find next to the deploy
folder. The compose file hardcodes `../../doubtfire-api` and `../../doubtfire-web`. If your
folders have different names, or are nested, or you only cloned the deploy repo, the build
fails and the error will not tell you why.

Make one parent folder and clone all three into it:

    mkdir ontrack && cd ontrack
    git clone https://github.com/ontrack-features-t2-2026/doubtfire-deploy.git
    git clone https://github.com/ontrack-features-t2-2026/doubtfire-api.git
    git clone https://github.com/ontrack-features-t2-2026/doubtfire-web.git

You should end up with exactly this:

    ontrack/
      doubtfire-deploy/
      doubtfire-api/
      doubtfire-web/

Do not rename the folders. Do not put doubtfire-api inside doubtfire-deploy. The deploy repo
already has empty folders with those names. They are uninitialised submodules. Your code
does not go there.

## Combined all-features 11.0.x

For a deterministic, disposable demonstration with a UI data switch, use the
isolated [all-features demo runtime](development/all-features-demo/README.md).
It owns a separate Compose project and database and is the preferred option for
showing CPD, PPI, and notification examples without retaining ad-hoc seed data.

The final source revisions are recorded in [HANDOVER.md](HANDOVER.md) and pinned
by this repository's API and web gitlinks. A fresh clone can initialise them
recursively. The demo launcher resolves sources in this order: explicit
`DF_DEMO_API_PATH`/`DF_DEMO_WEB_PATH`, complete sibling checkouts, then the
gitlinks. It fails before Compose if the chosen source is incomplete.

For editable sibling checkouts, use the published integration branch in each
repository and verify that its exact revision matches `HANDOVER.md`:

- **doubtfire-deploy**: `integration/deploy-all-features-foundation-20260824`
- **doubtfire-api**: `integration/11.0.x-all-features-20260824`
- **doubtfire-web**: `integration/11.0.x-all-features-20260824`

This is the singular local CPD, PPI, Email Notifications, and Mobile Notifications
integration. Do not mix it with the older individual feature branches. The api and web
containers run exactly what is checked out in the sibling folders, including uncommitted
changes.

The normal combined stack uses the base and local-path files under the dedicated
`notifications-demo` Compose project. That project name keeps its database and dependency
volumes separate from any older base-only stack and matches the notification verification
helpers. It exposes web, API, and Mailpit on <http://localhost:4400>,
<http://localhost:3200>, and <http://localhost:8225> respectively. Use the
ordered startup under **Steps to run** so a destructive demo seed cannot race
an eagerly starting API or worker.

To apply the retained isolated PPI setup as well, put its overlay last on every Compose
command:

```bash
docker compose -p ppi-live \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.ppi-live.yml \
  up -d --build
```

With the PPI overlay last, the effective web, API, and Mailpit ports are 4300, 3100, and
8125. The worker and API use the same PPI API image and generate links to the web app at
<http://localhost:4300>.

If either overlay is missing, one of the repositories is not on the combined integration
branch.

## Steps to run

All commands run from the deploy folder:

    cd doubtfire-deploy/development

**Keep the same `-p` project name and use both `-f` flags on every command.** The second file
points the build at your sibling folders and fixes the api proxy. If you selected the PPI
setup above, use `-p ppi-live` and include its third
`-f docker-compose.ppi-live.yml` flag last on every command too.

**Do not run `run-api-web.sh`.** It sits in this folder and looks like the way to start
things. It leaves out the second `-f` flag and fails on an empty build context.

1. Build the application images. Do this the first time and after switching the
   integration revision.

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml build \
      doubtfire-api doubtfire-sidekiq doubtfire-web

   The first build is slow. It installs gems and node packages.

2. Start only the infrastructure and wait for it to be ready.

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml up -d --wait \
      dev-db redis-sidekiq mailpit

3. Set up the database. Do this the first time, or any time the database is broken.

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml run --rm --no-deps doubtfire-api \
      bash -c "bundle exec rake db:populate"

   `db:populate` already drops, creates, migrates and seeds the database on its own. The
   longer command you may see elsewhere does the slowest part of setup twice.

   It takes a while and prints a lot. That is normal.

   Keep the API and worker stopped until this finishes. `db:populate` rebuilds
   the schema; letting an application entrypoint load the same schema at the
   same time can produce a duplicate-constraint failure.

4. Start the application processes and wait for them.

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml up -d --wait --wait-timeout 300 \
      doubtfire-api doubtfire-sidekiq doubtfire-web

5. Open the app.

   - Web: http://localhost:4400
   - API docs: http://localhost:3200/api/docs
   - Mail inbox: http://localhost:8225

6. Log in. Every test user has the password "password".

   - Student: student_1
   - Admin: aadmin
   - Convenor: aconvenor
   - Tutor: atutor

   You will usually want two of these signed in at once, because most notification work is
   one person doing something and another person being told about it. Use a private browser
   window for the second account instead of logging in and out.

   A student's dashboard is at `/projects/<project id>/dashboard`. There is no top-level
   `/dashboard` page. Typing that address sends you back to the home page.

## Where the emails go

**Open http://localhost:8225**

That is Mailpit, a mail catcher. Every email the app sends arrives there and you can read
it in your browser, subject, recipient and all. New mail appears without reloading the page.

The app never sends real email in development. Mailpit accepts everything and forwards
nothing, so you can safely put your own address on a test account.

- Web inbox: http://localhost:8225
- The api sends to it over SMTP on port 1025 inside Docker.

The `doubtfire-sidekiq` service takes provider delivery off the api request path. It
reads email from `mailers` and Web Push from `notifications`; the normal `up` command
starts it and sends caught email to Mailpit.

Both provider channels are asynchronous. If the worker is stopped, the in-app bell record
still appears immediately, while email and push wait safely in Redis until it starts again.

The worker listens only on `mailers` and `notifications`, so it does not run the rest of
the background jobs on `default`. That is on purpose. Several of them need a LaTeX
container this stack does not have, and a worker that picked those up would fail every
task submission and push the task back to "fix".

Check the worker and its recent job output:

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml ps doubtfire-sidekiq
    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml logs --tail 100 doubtfire-sidekiq

Stopping the worker does not lose queued notification email or push delivery. Starting it
again processes the pending channel work:

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml stop doubtfire-sidekiq
    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml start doubtfire-sidekiq

If the inbox stays empty:

1. Check the service is running:
   `docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml ps mailpit`
2. Check the api knows about it:

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml exec doubtfire-api printenv DF_SMTP_ADDRESS

   You want `mailpit`. If it is blank, your api container was started before the
   mail catcher was added. Recreate it:

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml up -d doubtfire-api

   A plain `restart` is not enough. Environment variables only change on recreate.

**Without Docker**, or if `DF_SMTP_ADDRESS` is unset, the api falls back to writing each
email to a file under `doubtfire-deploy/data/tmp/mails/`. One file per recipient address,
with new mail appended to the end. That is the old behaviour and it still works.

The comment in `doubtfire-api/config/environments/development.rb` used to say mail landed in
`doubtfire-api/tmp/mails`, which was wrong under Docker and sent people looking in an empty
folder in the wrong repository. That comment is now fixed.

## How to check it is working

- See the containers:

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml ps -a

- Check the api answers, from inside the container:

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml exec doubtfire-api curl -s localhost:3000/api/settings/public

- Check the web can reach the api through its proxy. You want 200:

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml exec doubtfire-web curl -s -o /dev/null -w "%{http_code}\n" localhost:4200/api/settings/public

- Check the mail catcher answers. You want 200:

    curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8225/

- List what is in the mail inbox without opening a browser:

    curl -s http://localhost:8225/api/v1/messages | head -c 400

- Read the logs:

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml logs doubtfire-api
    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml logs doubtfire-sidekiq
    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml logs doubtfire-web

## Asking for help

Grab these before you ask. The second one answers most questions on its own.

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml ps -a

On macOS or Linux:

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml logs --no-color --tail 200 doubtfire-api > api-log.txt 2>&1
    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml logs --no-color --tail 200 doubtfire-web > web-log.txt 2>&1

**On Windows, wrap it in `cmd /c` or the file comes out unreadable.**

    cmd /c "docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml logs --no-color --tail 200 doubtfire-api > api-log.txt 2>&1"
    cmd /c "docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml logs --no-color --tail 200 doubtfire-web > web-log.txt 2>&1"

PowerShell does two things to a plain `>` redirect that ruin the file. It writes UTF-16, so
every character comes out with a null byte next to it and most tools see binary rather than
text. And it treats anything the command sends to stderr as a PowerShell error object, so the
real message gets buried under `At line:1 char:1`, `CategoryInfo` and `FullyQualifiedErrorId`
noise, with the actual error split away from its own stack trace. `cmd /c` does neither.

Use Compose `ps -a` and not plain `docker ps`. Plain `docker ps` hides containers that have
already exited, and a container that exited is usually the whole problem. If the
`doubtfire-api` service says Exited, its log says why.

**Send logs as text, not as a screenshot.** Attach the two files, or paste the output inside
a fenced code block with three backticks. A screenshot of a terminal crops the part that
matters, cannot be searched, and in a Ruby crash the line you need is usually well below the
line you can see. Text can be matched against the errors in the next section in seconds. A
screenshot cannot.

Screenshots are still the right thing for anything visual. "The page says Temporarily
Unavailable" is a screenshot, because the rendering is the evidence. Anything with a stack
trace in it is text.

Say which branch each repo is on as well, and which Compose overlays you used. A lot of the
answers below turn on those two things. From `doubtfire-deploy/development`:

    git branch --show-current
    git -C ../../doubtfire-api branch --show-current
    git -C ../../doubtfire-web branch --show-current

## Problems and fixes

1. The api will not start. Error: "Your Ruby version is 3.1.7, but your Gemfile specified
   ~> 3.4.0".
   Cause: the image was built with old Ruby. `11.0.x` needs Ruby 3.4.
   Fix: rebuild the images. Add `--build` to the up command.

2. The web will not start. Error: "The Angular CLI requires a minimum Node.js version of
   v22".
   Cause: the image was built with old Node. `11.0.x` needs Node 22.
   Fix: rebuild the images. Add `--build`.

3. `up` stops straight away. Error: "service overseer-worker-1 has neither an image nor a
   build context".
   Cause: an old local-paths file had overseer services with no image.
   Fix: already fixed. The combined local-paths overlay contains complete overrides only
   for services used by this stack.

4. The web crashes. Error: "Missing script: start-compose".
   Cause: `11.0.x` renamed that script to "start".
   Fix: already fixed. The local-paths file runs "npm start".

5. The api crashes while migrating. Error: "Table 'doubtfire-dev.task_prerequisites' doesn't
   exist".
   Cause: the database has old, half-set-up data. The api container runs `db:migrate` every
   time it starts, so a half-populated database makes it crash on boot over and over, before
   it ever listens on port 3000.
   Fix: reset the database. Run step 2 above.

   **If step 2 fails too, throw the database away and start it again.** Step 2 asks MariaDB
   to drop the database, and a server that cannot read its own files cannot drop them
   either. `-v` deletes the volume the database lives in, which is the only thing that
   clears it.

   ```bash
   docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml down -v
   ```

   Then repeat **Steps to run** 1–4. Those steps wait for MariaDB, keep API and
   worker schema readers stopped during `db:populate`, and start them only after
   the seed is complete.

   This deletes your local data. That is fine, everything in it came from `db:populate` and
   the command above puts it all back. `-v` also clears the web `node_modules` volume, so the
   next start is slower while npm reinstalls. Your code is untouched either way: the repos
   are bind mounted, not copied.

6. The app loads but shows "Temporarily Unavailable" and the title stays "Loading...".
   **Check the api is running before you read any further.** Run the Compose `ps -a` command
   under **How to check it is working**. If the `doubtfire-api` service is missing or says
   Exited, this is not a proxy problem; it is problems 5, 10 or 14, and the Compose service
   log says which.
   Cause: the web app cannot reach the api. The proxy points at localhost:3000, which is
   wrong inside the container. The api is a different Compose service named doubtfire-api.
   Fix: already fixed. The local-paths file mounts `proxy.conf.docker.json`, which points at
   doubtfire-api:3000. If you still see the error, rebuild the web container and reload:

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml up -d --build doubtfire-web

7. The build fails straight away, or complains about an empty or missing build context.
   Cause: your folders are not laid out the way the compose file expects, or you only cloned
   the deploy repo.
   Fix: see "Clone all three repos side by side" above. All three must sit next to each
   other, with their original names.

8. You switched branch, and now the web container fails on a package it should have.
   Cause: node_modules lives in a Docker volume that survives `docker compose down`, so a
   branch with different dependencies installs on top of stale packages.
   Fix: clear the volume and rebuild.

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml down -v

   **`-v` does delete your database**, because that is a volume too. Repeat
   **Steps to run** 1–4 to rebuild, repopulate, and start safely. Your code is
   not touched; the repos are bind mounted rather than copied.

9. You trigger an email and nothing appears at http://localhost:8225.
   Cause: nearly always an api container started before the mail catcher existed, so it
   still has no `DF_SMTP_ADDRESS` and is writing files instead.
   Fix: recreate it. `restart` does not pick up new environment variables.

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml up -d doubtfire-api

   Confirm with the Compose `exec doubtfire-api printenv DF_SMTP_ADDRESS` command under
   **Where the emails go**, which should print `mailpit`.

10. The api container will not start. Error: "Could not find <some gem> in locally installed
   gems (Bundler::GemNotFound)".
   Cause: somebody added a gem to the api `Gemfile`. Gems are installed into the image when
   it is built, not into a volume, so a container started from the old image does not have
   it. The api then crash-loops before it ever listens on port 3000.
   Fix: rebuild the image.

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml up -d --build doubtfire-api

   Running `bundle install` with Compose `exec` looks like it works and does not survive.
   The gems land in the running container's writable layer and are thrown away the next
   time the container is recreated.

11. The app starts throwing 500s while you are using it, and the log says
   "ActiveRecord::LockWaitTimeout: Lock wait timeout exceeded".
   Cause: the base Compose file uses one database for development and tests. The combined
   local-paths overlay fixes this by creating and selecting
   `doubtfire-notifications-test`. Seeing this error usually means the api was started
   without the required local-paths overlay.
   Fix: stop the base-only stack and restart with both required `-f` flags. Do not run a
   database reset while anyone is using the app or during a demo.

12. You post a comment, get a 403 back, and no email arrives. The error says "Comment
   duplicates last comment, so ignored".
   Cause: OnTrack drops a comment whose text is identical to the previous comment on that
   task. No comment is created, so no notification and no email. This is existing behaviour
   in `app/api/task_comments_api.rb`, not something notifications introduced.
   Fix: type something different. When rehearsing a demo, vary the text each time.

13. `git status` in doubtfire-deploy shows an untracked `doubtfire-overseer/` folder.
   Cause: it is a leftover checkout from another branch. `11.0.x` does not use it. Most
   people will never see it.
   Fix: none needed. Leave it alone. Do not `git add` it and do not delete it.

14. `rake db:populate` fails part way through. Error: "Error on rename of
   './doubtfire@002ddev/<some table>' to './doubtfire@002ddev/#sql-backup-1-7' (errno: 194
   "Tablespace is missing for a table")".
   **This is a Windows problem and it is not your data.** It happens on a completely fresh
   database, so deleting things and starting again does not help. Three people tried that and
   got the identical error on the identical table.
   Cause: the database used to live in a bind mount, `../data/database`, a folder on your own
   machine shared into the container. InnoDB cannot reliably rename a table across that share
   on Windows, and it reports errno 194. Loading the schema renames tables while it adds
   foreign keys, so `db:populate` trips over it on the first table in that pass every time.
   It is not a Rails problem and it is not corruption. See docker-library/mariadb#331, which
   reproduces it in three SQL statements.
   Fix: already fixed. The database is a named Docker volume now, which lives inside Docker's
   own filesystem and never touches the Windows one. Pull the latest `11.0.x`, then:

   ```bash
   docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml down -v
   ```

   Then repeat **Steps to run** 1–4 so schema writers cannot race.

   The old `doubtfire-deploy/data/database` folder is dead after that and you can delete it.
   Nothing reads it any more.
   You will usually see the api container die too, because it migrates on boot. Same problem,
   and the same reset fixes both.

15. `bundle exec rake db:populate` fails instantly. On Windows the error is "WSL ... ERROR:
   CreateProcessCommon:800: execvpe(/bin/bash) failed: No such file or directory". On macOS
   it is "bundle: command not found".
   Cause: the command ran on your own machine instead of inside the api container. Ruby and
   the gems are only in the container. Nothing needs to be installed on your machine.
   Fix: use the whole command from step 2. The part before `bash -c` is not optional.

     ```bash
     docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml run --rm --no-deps doubtfire-api bash -c "bundle exec rake db:populate"
     ```

     This single-line form avoids the PowerShell line-continuation issue.

## Notes

- Docker mounts your local folders. The web and api run your branch code, including changes
  you have not committed yet.
- The first time you move to `11.0.x` you must rebuild the images with `--build`. Old images
  will not work.
- The normal combined stack publishes API 3200, web 4400, Mailpit 8225, and Mailpit SMTP
  1225. The database and Redis are internal to Docker, so a database client on your Mac
  cannot connect to them. To look at the database, go through the api service:

    docker compose -p notifications-demo -f docker-compose.yml -f docker-compose.local-paths.yml exec doubtfire-api bash -c "bundle exec rails console"

## Peer Progress Indicator configuration

The local API container receives these non-secret development defaults:

- `DF_PPI_MINIMUM_COHORT_SIZE=21`
- `DF_PPI_STALE_AFTER_HOURS=48`

`DF_PPI_MINIMUM_COHORT_SIZE=21` matches the API's own floor.
`PeerProgressApi::MINIMUM_SAFE_COHORT_SIZE` is 21 and `minimum_cohort_size!`
returns 503 for anything below it, so a lower value disables the endpoint for
enabled units rather than publishing a smaller cohort. You can raise this
value, you cannot lower it. `positive_integer_env!` separately rejects a
missing, zero, negative or non-integer value.

The floor is 21 remaining peers because the API quantises percentages into
10-point buckets. Before thresholding or quantising, it uses the exact internal
snapshot counts to remove the authenticated student's known task status and
upload contribution. A target-grade band therefore needs at least 22 eligible
students, including the reader, to leave 21 peers. At 20 peers each person
accounts for exactly half a bucket, leaving some rounded outputs that map to
only one possible count. At 21 peers each person's share is smaller than half a
bucket, so every published scalar output maps to at least two possible counts,
including the edge buckets. Changing either number without the other breaks
that guarantee, so `MINIMUM_SAFE_COHORT_SIZE` and
`PERCENTAGE_BUCKET_SIZE` are asserted together in the API test suite.

That scalar guarantee protects the compact completed percentage and the
additive submitted wire-compatibility percentage. The advanced 15-status
distribution also considers all peer-only rounded buckets together: the API
releases the entire vector only when every status has at least two feasible raw
peer counts after applying the sum constraint. If that stronger check fails,
the compact value can remain available while the detailed vector is withheld.
Do not lower the peer floor to force either view to appear.

Reader subtraction requires exact internal `submitted_count` and
`status_counts` fields. Snapshots created before migration `20260824000003`
have neither and deliberately return no percentages through the new API until
the aggregation job refreshes them. The endpoint also fails closed if the
reader's project membership or task changed after the snapshot, because
subtracting newer viewer context from an older aggregate would be unsafe.

Use the combined API integration branch named above; the older
`ppi/student-progress-endpoint` verification pin is superseded. That API
revision must include the privacy fix that raises
`PeerProgressApi::MINIMUM_SAFE_COHORT_SIZE` to 21. The deploy and API changes
must not be merged independently.

`DF_PPI_STALE_AFTER_HOURS=48` is the local maximum snapshot age. A snapshot
older than this is returned as stale, and the response withholds the
percentage entirely rather than returning an old one.

The combined local stack starts Redis and the Sidekiq worker. That worker only
listens on the `mailers` and `notifications` queues, so it does not pick up
`AggregatePeerProgressJob` from `default`; the sample task below does the work
directly and does not depend on it.
To create the privacy-safe PPI demo data deterministically, run the dedicated
sample task in the same `ppi-live` project:

```bash
docker compose -p ppi-live \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.ppi-live.yml \
  run --rm doubtfire-api bash -c "bundle exec rake db:ppi_sample_data"
```

This task creates or repairs the synthetic `PPI1001` and `PPI1002` units. It
derives the students per class from `DF_PPI_MINIMUM_COHORT_SIZE`, rounding up so
the two-class exact-grade cohorts leave at least the configured number of peers
after excluding any one reader. With the local setting, each class has 11
students per grade and each target-grade cohort on a fresh or legacy sample
database has 22 students: exactly 21 remaining peers for any reader. The task
changes the PPI setting only for those synthetic
units, repairs the current seed-owned user roles, unit and task definitions,
tutorial capacity and enrolments, and writes and validates fresh snapshots
before it returns. It is safe to run again against a database previously
populated by this task; surplus students from an earlier higher threshold are
retained, so later cohorts can be above the configured minimum.

Verify the feature flag, exact-grade cohort sizes, and the 28 seed-owned fresh
task/grade snapshots per unit:

```bash
docker compose -p ppi-live \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.ppi-live.yml \
  exec doubtfire-api bundle exec rails runner \
  'minimum = Integer(ENV.fetch("DF_PPI_MINIMUM_COHORT_SIZE"), 10); \
   stale_after_hours = Integer(ENV.fetch("DF_PPI_STALE_AFTER_HOURS"), 10); \
   raise "Invalid PPI configuration" unless minimum >= PeerProgressApi::MINIMUM_SAFE_COHORT_SIZE && stale_after_hours.positive?; \
   fresh_after = stale_after_hours.hours.ago; \
   grades = [0, 1, 2, 3]; codes = %w[PPI1001 PPI1002]; \
   abbreviations = (1..7).map { |number| "T#{number}" }; \
   units = codes.map do |code| \
     matches = Unit.where(code: code).to_a; \
     raise "Expected exactly one #{code} unit" unless matches.one?; \
     matches.first; \
   end; \
   units.each do |unit| \
     cohorts = unit.active_projects.group(:target_grade).count; \
     task_defs = unit.task_definitions.where(abbreviation: abbreviations); \
     unit_number = unit.code.delete_prefix("PPI100"); \
     projects = unit.active_projects.joins(:user).where("users.username LIKE ?", "ppi_u#{unit_number}c%"); \
     tasks = Task.where(project_id: projects.select(:id), task_definition_id: task_defs.select(:id)).includes(:task_definition, :project); \
     demo = unit.peer_progress_snapshots.where(task_definition_id: task_defs.select(:id), target_grade: grades); \
     latest_changes = grades.index_with { |grade| unit.active_projects.where(target_grade: grade).maximum(:target_grade_changed_at) }; \
     valid = unit.active? && unit.peer_progress_enabled? && !unit.allow_flexible_dates? && \
       task_defs.count == 7 && task_defs.all? { |definition| definition.target_grade.zero? } && \
       projects.count >= 2 * grades.length * minimum.fdiv(2).ceil && \
       projects.all? { |project| project.enrolled? && project.user.role_id == Role.student_id && grades.include?(project.target_grade) } && \
       tasks.count == projects.count * task_defs.count && \
       tasks.all? { |task| task.local_start_date.present? && task.local_start_date <= Time.zone.now && task.task_definition.target_grade <= task.project.target_grade } && \
       demo.count == 28 && \
       grades.all? { |grade| cohorts.fetch(grade, 0) - 1 >= minimum } && \
       demo.all? { |snapshot| !snapshot.submitted_count.nil? && !snapshot.status_counts.nil? && snapshot.cohort_size == cohorts.fetch(snapshot.target_grade) && \
         snapshot.calculated_at >= fresh_after && snapshot.calculated_at >= latest_changes.fetch(snapshot.target_grade) }; \
     raise "#{unit.code} is not PPI demo-ready" unless valid; \
     puts "#{unit.code}: enabled=true cohorts=#{cohorts.slice(*grades).inspect} fresh_demo_snapshots=#{demo.count}"; \
   end'
```

At the checked-in local setting on a fresh or legacy sample database, both lines
report `enabled=true`, cohorts `{0=>22, 1=>22, 2=>22, 3=>22}`, and
`fresh_demo_snapshots=28`. Cohorts can be higher after a run with a higher valid
threshold because the seed never removes students. In every case it adds enough
students per class to leave at least the configured peer threshold after the
reader is excluded. Never lower the configured floor to make a demo visible.

The production Compose template supplies the same approved values through
`production/.env.production.example`, which you copy to `production/.env.production`
on the host. That file is deliberately not committed. These values are not
secrets, but both must be present because an enabled unit with an eligible
snapshot returns 503 when either setting is missing or invalid.
