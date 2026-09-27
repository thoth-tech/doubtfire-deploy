
# Doubtfire Deploy

Doubtfire is a feedback-driven learning support system.

The Doubtfire Deploy repository is used to manage releases of Doubtfire using containers.

## Documentation

- [Demo guide](DEMO.md)
- [Release guide](RELEASING.md)
- [Desktop PWA installation and release checks](DESKTOP-PWA.md)
- [Migration guide](MIGRATING.md)
- [Notifications integration](NOTIFICATIONS-INTEGRATION.md)
- [All-features integration](ALL-FEATURES-INTEGRATION.md)
- [Unit Hub, Teams announcements and class calendars](UNIT-HUB.md)
- [Development Docker files](development/development-dockerfiles.md)
- [OnTrack Podman setup](docs/ONTRACK_PODMAN_SETUP.md)

## Table of Contents

- [Doubtfire Deploy](#doubtfire-deploy)
  - [Documentation](#documentation)
  - [Table of Contents](#table-of-contents)
  - [How to use this project for development](#how-to-use-this-project-for-development)
  - [How to use this project for deployment](#how-to-use-this-project-for-deployment)


## How to use this project for development

Use [RUNNING-LOCALLY.md](RUNNING-LOCALLY.md) for the current combined checkout
and demo workflow. [CONTRIBUTING.md](CONTRIBUTING.md) retains general project and
commit guidance, but its older runtime and branch examples are not the 11.0.x
release contract.

## How to use this project for deployment

Start with the release-owner checklist in [HANDOVER.md](HANDOVER.md), then use
the fail-closed production Compose stack and operator runbook in
[DEPLOYING.md](DEPLOYING.md). The deployment requires institution-owned secrets,
TLS, identity-provider and SMTP settings, persistent storage, monitoring,
restored backups, manual acceptance, and immutable container image digests;
none are defaulted in the repository.

The isolated all-features demonstration remains available under
[`development/all-features-demo`](development/all-features-demo/README.md). It
uses synthetic data and development-only accounts and is never production
configuration.
