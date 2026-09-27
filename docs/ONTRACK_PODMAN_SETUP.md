# Running OnTrack locally with Podman on Bazzite or Fedora

> **Historical, unsupported troubleshooting transcript.** Its service names,
> ports, and generated override no longer match the tracked three-file Compose
> merge, and its setup commands must not be treated as the current demo or
> production runbook. Use [RUNNING-LOCALLY.md](../RUNNING-LOCALLY.md) or the
> [retained all-features demo](../development/all-features-demo/README.md).
> This record remains only as background for future reviewed Podman support.

This guide records the changes that were needed to run the existing OnTrack development environment with rootless Podman on Bazzite.

The normal Docker Compose files were kept. A separate `docker-compose.podman.yml` file was added for the Podman-specific changes.

This should also be useful for Fedora and other Linux systems where SELinux is enabled.

## What was different with Podman

The main issues were not with the OnTrack code itself. They came from differences between Docker and rootless Podman:

- SELinux blocked some bind-mounted folders.
- MariaDB could not change ownership on the host database folder.
- The frontend container could not write to `package-lock.json` or the Angular cache.
- An old Docker container was already using the Mailpit ports.
- Compose reused an older API image with the wrong Ruby version.
- Podman tried to relabel the frontend `node_modules` folder and failed.

The final setup keeps the normal Docker files unchanged and handles these problems in a local Podman override.

## Important notes

- Run Podman as your normal user. Do not use `sudo podman`.
- Run the Compose commands from `doubtfire-deploy/development`.
- Use all three Compose files in every Podman command.
- Do not run the Docker and Podman OnTrack stacks on the same ports.
- Do not use `podman compose down -v` unless you want to delete the local database.
- Do not disable SELinux globally.
- Do not use `chmod 777` as a workaround.
- Keep `docker-compose.podman.yml` local unless the team decides to support it officially.

## 1. Check the repository layout

The three repositories must be beside each other:

```text
Ontrack Dev/
|-- doubtfire-api/
|-- doubtfire-deploy/
`-- doubtfire-web/
```

Go to the development folder:

```bash
cd "/var/home/$USER/dev/Ontrack Dev/doubtfire-deploy/development"
```

Your path may be under `/home` rather than `/var/home`. Both can point to the same location on Bazzite.

Check the repository paths:

```bash
realpath ../../doubtfire-api
realpath ../../doubtfire-web
```

Check the main files:

```bash
[[ -f ../../doubtfire-api/Gemfile ]] && echo "API path is correct" || echo "API Gemfile is missing"
[[ -f ../../doubtfire-web/package.json ]] && echo "Web path is correct" || echo "Web package.json is missing"
```

Do not put backslashes before `&&` or `||` when running these as one-line commands. Doing that caused a `binary operator expected` error during our setup.

## 2. Stop any old Docker version of OnTrack

We had an old Docker Mailpit container using ports `1025` and `8025`. Podman could not start its own Mailpit container until those ports were released.

Check the ports used by OnTrack:

```bash
sudo ss -ltnp | grep -E ':(1025|8025|3000|4200)([[:space:]]|$)' || true
```

Check Docker containers using those ports:

```bash
sudo docker ps \
  --format 'table {{.ID}}\t{{.Names}}\t{{.Ports}}' \
  | grep -E '1025|8025|3000|4200' || true
```

If an old Docker OnTrack stack is running, stop it from the development folder:

```bash
sudo docker compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  down --remove-orphans
```

Do not kill `docker-proxy` directly. Stop the Docker container that created it.

Confirm the ports are free:

```bash
sudo ss -ltnp | grep -E ':(1025|8025|3000|4200)([[:space:]]|$)' \
  || echo "Required OnTrack ports are free"
```

## 3. Create the Podman Compose override

Create `docker-compose.podman.yml` inside `doubtfire-deploy/development`:

```bash
cat > docker-compose.podman.yml <<'YAML'
services:
  dev-db:
    volumes:
      - podman_db_data:/var/lib/mysql

  doubtfire-api:
    image: localhost/ontrack-doubtfire-api:11.0-local
    volumes:
      - ../../doubtfire-api/:/doubtfire:z
      - ../data/tmp:/doubtfire/tmp:z
      - ../data/student-work:/student-work:z

  doubtfire-sidekiq:
    image: localhost/ontrack-doubtfire-api:11.0-local
    volumes:
      - ../../doubtfire-api/:/doubtfire:z
      - ../data/tmp:/doubtfire/tmp:z
      - ../data/student-work:/student-work:z

  doubtfire-web:
    image: localhost/ontrack-doubtfire-web:11.0-local
    userns_mode: "keep-id:uid=1000,gid=1000"
    security_opt:
      - label=disable
    command: /bin/bash -c 'npm install && npm start'
    volumes:
      - ../../doubtfire-web:/doubtfire-web
      - ./proxy.conf.docker.json:/doubtfire-web/proxy.conf.json:ro

volumes:
  podman_db_data:
YAML
```

### Why these changes are needed

`podman_db_data` is a Podman-managed volume for MariaDB. The original host bind mount failed because rootless Podman could not change ownership inside `/var/lib/mysql`.

The local image names stop Compose from pulling or reusing an older public API image. We hit a Bundler exit code `18` because the old image had a Ruby version that did not match the current API Gemfile.

The API mounts use `:z` so SELinux allows the source folders to be shared with the API containers.

`doubtfire-sidekiq` is the background worker and runs the same API image, so it repeats the API block exactly. Without it the worker keeps the public `8.0.x-dev` tag from `docker-compose.yml` while the API uses the local build, and `up -d --no-build` pulls that old image instead of failing. It needs no separate build. Building `doubtfire-api` in step 8 produces the image both services use.

The frontend uses `label=disable` because Podman failed while trying to relabel the full frontend repository, especially `node_modules`.

The frontend also uses `keep-id` so the Node user inside the container can write to files owned by the local user.

The command uses `npm install && npm start` so Angular does not start after a failed dependency install.

## 4. Check the merged Compose configuration

Run:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  config > /tmp/ontrack-podman-config.yml
```

Check the database section:

```bash
grep -n -A20 '^  dev-db:' /tmp/ontrack-podman-config.yml
```

The database should use a named volume at `/var/lib/mysql`. It should not use `../data/database` as the active database mount.

Check the frontend section:

```bash
grep -n -A50 '^  doubtfire-web:' /tmp/ontrack-podman-config.yml
```

Confirm that it contains:

```text
localhost/ontrack-doubtfire-web:11.0-local
keep-id:uid=1000,gid=1000
label=disable
npm install && npm start
```

Warnings saying that the Compose `version` field is obsolete are harmless.

The message saying Podman is executing an external Compose provider is also normal. On this system, `podman compose` used the installed Docker Compose plugin as its Compose provider.

## 5. Prepare the API writable folders

SELinux originally blocked the API mount. Later, Podman also failed with an `lsetxattr` error on `doubtfire-api/tmp`.

Create the writable folders:

```bash
sudo mkdir -p \
  ../../doubtfire-api/tmp \
  ../data/tmp \
  ../data/student-work
```

Return ownership to the current user:

```bash
sudo chown -R "$(id -u):$(id -g)" \
  ../../doubtfire-api/tmp \
  ../data/tmp \
  ../data/student-work
```

Give the owner write access:

```bash
sudo chmod -R u+rwX \
  ../../doubtfire-api/tmp \
  ../data/tmp \
  ../data/student-work
```

Apply the SELinux container label:

```bash
sudo chcon -R system_u:object_r:container_file_t:s0 \
  ../../doubtfire-api/tmp \
  ../data/tmp \
  ../data/student-work
```

Check the labels:

```bash
ls -ldZ \
  ../../doubtfire-api/tmp \
  ../data/tmp \
  ../data/student-work
```

Each path should show `container_file_t`.

## 6. Prepare the frontend writable files

The frontend initially failed with permission errors for:

```text
/doubtfire-web/package-lock.json
/doubtfire-web/.angular/cache
```

Fix `package-lock.json` if it exists:

```bash
if [ -f ../../doubtfire-web/package-lock.json ]; then
  sudo chown "$(id -u):$(id -g)" ../../doubtfire-web/package-lock.json
  sudo chmod u+rw ../../doubtfire-web/package-lock.json
fi
```

The original workaround recursively deleted a privileged cwd-relative cache
path. Do not repeat it. The supported local workflows use their tracked Compose
and named-volume contracts; a future Podman procedure must resolve and validate
an exact disposable cache target before offering any cleanup operation.

Check the ownership:

```bash
ls -ldn \
  ../../doubtfire-web \
  ../../doubtfire-web/.angular \
  ../../doubtfire-web/package-lock.json
```

The owner should match the result of:

```bash
id -u
```

## 7. Clean up failed containers and the old dependency volume

Stop the Podman stack without deleting volumes:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  down --remove-orphans
```

Remove failed temporary containers if they exist:

```bash
podman rm -f ontrack-db-populate 2>/dev/null || true
podman rm -f doubtfire-web 2>/dev/null || true
```

Find the frontend dependency volume:

```bash
podman volume ls --format '{{.Name}}' | grep web_node_modules || true
```

In our setup, the volume was called:

```text
development_web_node_modules
```

Remove only that dependency volume:

```bash
podman volume rm development_web_node_modules 2>/dev/null || true
```

The project prefix may be different on another computer. Remove the volume ending in `web_node_modules`.

Do not remove the volume ending in `podman_db_data`.

## 8. Build the current API and frontend images

Check the API Dockerfile and current branches:

```bash
grep -n '^FROM ruby:' ../../doubtfire-api/Dockerfile
git -C ../../doubtfire-api branch --show-current
git -C ../../doubtfire-web branch --show-current
```

Build the API from scratch:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  build --pull --no-cache doubtfire-api
```

Build the frontend:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  build --pull doubtfire-web
```

Confirm that the local images exist:

```bash
podman images | grep -E 'ontrack-doubtfire-(api|web)'
```

Check the API Ruby and Bundler versions:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  run --rm -T \
  --no-deps \
  --entrypoint bash \
  doubtfire-api \
  -lc 'ruby -v; bundle -v'
```

The Ruby version must match the requirement in the current API Gemfile.

Check the frontend image user:

```bash
podman run --rm \
  --entrypoint id \
  localhost/ontrack-doubtfire-web:11.0-local
```

The image used during this setup reported UID and GID `1000`. If a future image uses another UID or GID, update the values in `userns_mode`.

## 9. Start MariaDB, Redis, and Mailpit

Start the supporting services first:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  up -d dev-db redis-sidekiq mailpit
```

Wait for MariaDB to initialise:

```bash
sleep 20
```

Check the containers:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  ps -a
```

Confirm MariaDB is ready:

```bash
podman exec df-compose-dev-db \
  mariadb-admin ping \
  -h 127.0.0.1 \
  -uroot \
  -pdb-root-password
```

Expected output:

```text
mysqld is alive
```

If the database exits, check its logs:

```bash
podman logs --tail 200 df-compose-dev-db
```

## 10. Populate the database

Use a named detached container so the logs remain available:

```bash
podman rm -f ontrack-db-populate 2>/dev/null || true
```

Start the population task:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  run -d \
  --no-deps \
  --name ontrack-db-populate \
  --entrypoint bash \
  doubtfire-api \
  -lc 'bundle exec rake --trace db:populate'
```

Follow the logs:

```bash
podman logs -f --tail 100 ontrack-db-populate
```

Check the status:

```bash
podman inspect ontrack-db-populate \
  --format 'status={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}'
```

If the status is still `running`, do not try to remove it. Wait for it to finish:

```bash
podman wait ontrack-db-populate
```

A successful task returns:

```text
0
```

The final inspect result should be:

```text
status=exited exit=0 error=
```

After a successful run, remove the temporary container:

```bash
podman rm ontrack-db-populate
```

If it exits with a non-zero code, keep the container until you have checked the logs:

```bash
podman logs --tail 300 ontrack-db-populate
```

## 11. Start the complete OnTrack environment

Start all services using the images that were already built:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  up -d --no-build
```

Check everything:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  ps -a
```

The main containers should be running:

```text
df-compose-dev-db
df-compose-mailpit
df-compose-redis-sidekiq
doubtfire-api
doubtfire-sidekiq
doubtfire-web
```

Check the application logs:

```bash
podman logs --tail 100 doubtfire-api
podman logs --tail 150 doubtfire-web
```

NPM deprecation warnings are not a startup failure. The important errors to look for are `EACCES`, `permission denied`, or `lsetxattr`.

## 12. Check frontend write access

Run:

```bash
podman exec doubtfire-web bash -lc '
  echo "Container identity:"
  id

  test -w /doubtfire-web/package-lock.json &&
    echo "package-lock.json is writable" ||
    echo "package-lock.json is not writable"

  mkdir -p /doubtfire-web/.angular/cache/podman-write-test &&
  rmdir /doubtfire-web/.angular/cache/podman-write-test &&
    echo "Angular cache is writable"
'
```

Both write checks should succeed.

## 13. Open the local services

```text
OnTrack web:        http://localhost:4200
API documentation: http://localhost:3000/api/docs
Mailpit:            http://localhost:8025
```

Common local test accounts use the password `password`:

```text
student_1
atutor
aconvenor
aadmin
```

## Normal commands after the first setup

Start the environment:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  up -d --no-build
```

Stop the environment:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  down
```

Check status:

```bash
podman compose \
  -f docker-compose.yml \
  -f docker-compose.local-paths.yml \
  -f docker-compose.podman.yml \
  ps -a
```

Follow API logs:

```bash
podman logs -f doubtfire-api
```

Follow frontend logs:

```bash
podman logs -f doubtfire-web
```

## Errors we hit

| Error or message | Cause | Fix |
|---|---|---|
| `binary operator expected` | A Bash test command was pasted with incorrect backslashes | Run the test as one normal line |
| `/doubtfire: Permission denied` | SELinux blocked the API bind mount | Use `:z` on the API mounts |
| `lsetxattr ... doubtfire-api/tmp ... operation not permitted` | API writable folders had unsuitable ownership or SELinux labels | Use `chown`, `chmod`, and `chcon` on the writable folders |
| `bind: address already in use` on port 1025 | An old Docker Mailpit container was still running | Stop the old Docker stack |
| `/var/lib/mysql: Permission denied` | Rootless Podman could not change ownership on the database bind mount | Use the `podman_db_data` named volume |
| Database population exited with code 18 | Compose used an older API image with the wrong Ruby version | Use unique local image names and rebuild the API |
| `ontrack-db-populate` could not be removed | The population job was still running | Follow its logs and wait for it to exit |
| `lsetxattr ... doubtfire-web/node_modules` | Podman tried to relabel the full frontend repository | Use `security_opt: label=disable` for the frontend |
| `EACCES` for `package-lock.json` | The frontend user could not write to the host file | Use `keep-id` and repair the file ownership |
| `EACCES` for `.angular/cache` | The Angular cache had the wrong owner | Delete and recreate `.angular` as the local user |
| Angular started after `npm install` failed | The original command used `;` | Use `npm install && npm start` |
| `version is obsolete` | The Compose files contain an older `version` field | Harmless warning |
| `Executing external compose provider` | `podman compose` is using an installed Compose provider | Normal behaviour |

## Final Podman override

The final working `docker-compose.podman.yml` was:

```yaml
services:
  dev-db:
    volumes:
      - podman_db_data:/var/lib/mysql

  doubtfire-api:
    image: localhost/ontrack-doubtfire-api:11.0-local
    volumes:
      - ../../doubtfire-api/:/doubtfire:z
      - ../data/tmp:/doubtfire/tmp:z
      - ../data/student-work:/student-work:z

  doubtfire-sidekiq:
    image: localhost/ontrack-doubtfire-api:11.0-local
    volumes:
      - ../../doubtfire-api/:/doubtfire:z
      - ../data/tmp:/doubtfire/tmp:z
      - ../data/student-work:/student-work:z

  doubtfire-web:
    image: localhost/ontrack-doubtfire-web:11.0-local
    userns_mode: "keep-id:uid=1000,gid=1000"
    security_opt:
      - label=disable
    command: /bin/bash -c 'npm install && npm start'
    volumes:
      - ../../doubtfire-web:/doubtfire-web
      - ./proxy.conf.docker.json:/doubtfire-web/proxy.conf.json:ro

volumes:
  podman_db_data:
```

The existing OnTrack Docker setup did not need to be rewritten. The working solution was a small local override for SELinux, rootless file ownership, MariaDB storage, and the local API and frontend images.
