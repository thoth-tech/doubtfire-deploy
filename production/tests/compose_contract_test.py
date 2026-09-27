#!/usr/bin/env python3

import json
import sys


def require(condition, message):
    if not condition:
        raise AssertionError(message)


with open(sys.argv[1], encoding="utf-8") as compose_file:
    compose = json.load(compose_file)

services = compose["services"]
expected_services = {
    "apiserver",
    "docker-socket-proxy",
    "doubtfire-db",
    "jplag",
    "migrate",
    "pdfgen",
    "proxy",
    "redis-sidekiq",
    "sidekiq",
    "texlive-pdfgen",
    "texlive-sidekiq",
    "webserver",
}
require(set(services) == expected_services, "unexpected production service set")

published_ports = []
for service_name, service in services.items():
    for port in service.get("ports", []):
        published_ports.append((service_name, int(port["target"]), int(port["published"])))
require(
    sorted(published_ports) == [("proxy", 80, 80), ("proxy", 443, 443)],
    "only proxy ports 80 and 443 may be published",
)

for network_name in ("data", "docker-api"):
    require(compose["networks"][network_name]["internal"] is True, f"{network_name} must be internal")

long_running = expected_services - {"migrate"}
for service_name in long_running:
    require(
        services[service_name].get("restart") == "unless-stopped",
        f"{service_name} must restart unless stopped",
    )

for service_name in ("apiserver", "migrate", "pdfgen", "sidekiq"):
    environment = services[service_name]["environment"]
    require(environment["RAILS_ENV"] == "production", f"{service_name} must run Rails in production")
    require("MARIADB_ROOT_PASSWORD" not in environment, f"{service_name} received the database root password")
    require("TLS_PRIVATE_KEY_PATH" not in environment, f"{service_name} received the TLS key path")
    require(environment["OVERSEER_ENABLED"] == "0", f"{service_name} must keep Overseer disabled")

live_feature_keys = {
    "DF_PPI_MINIMUM_COHORT_SIZE",
    "DF_PPI_STALE_AFTER_HOURS",
    "DOUBTFIRE_VAPID_PUBLIC_KEY",
    "DOUBTFIRE_VAPID_PRIVATE_KEY",
    "DOUBTFIRE_VAPID_SUBJECT",
}
for service_name in ("apiserver", "sidekiq"):
    environment = services[service_name]["environment"]
    for key in live_feature_keys:
        require(
            bool(environment.get(key)),
            f"{service_name} must receive the validated {key} value",
        )

api_environment = services["apiserver"]["environment"]
sidekiq_environment = services["sidekiq"]["environment"]
teams_scope_keys = {
    "DF_TEAMS_ANNOUNCEMENTS_ENABLED": "false",
    "DF_TEAMS_TENANT_ID": "",
    "DF_TEAMS_CHANNEL_MAPPINGS": "[]",
}
teams_credential_keys = {"DF_TEAMS_CLIENT_ID", "DF_TEAMS_CLIENT_SECRET"}
teams_credentials = {key: "" for key in teams_credential_keys}
if len(sys.argv) > 2 and sys.argv[2] == "--teams-configured":
    teams_scope_keys.update({
        "DF_TEAMS_ANNOUNCEMENTS_ENABLED": "true",
        "DF_TEAMS_TENANT_ID": "11111111-1111-1111-1111-111111111111",
        "DF_TEAMS_CHANNEL_MAPPINGS": '[{"unit_id":111,"team_id":"22222222-2222-2222-2222-222222222222","channel_id":"19:fixture@thread.tacv2","publisher_ids":["33333333-3333-3333-3333-333333333333"],"student_visible":true}]',
    })
    teams_credentials.update({
        "DF_TEAMS_CLIENT_ID": "44444444-4444-4444-4444-444444444444",
        "DF_TEAMS_CLIENT_SECRET": "fixture-only-teams-application-secret",
    })
for key, default in teams_scope_keys.items():
    expected = default
    require(api_environment.get(key) == expected, f"API received unexpected {key}")
    require(sidekiq_environment.get(key) == expected, f"Sidekiq received unexpected {key}")
for key in teams_credential_keys:
    require(
        sidekiq_environment.get(key) == teams_credentials[key],
        f"Sidekiq received unexpected {key}",
    )
for service_name, service in services.items():
    environment = service.get("environment", {})
    if service_name != "sidekiq":
        for key in teams_credential_keys:
            require(key not in environment, f"{service_name} must not receive Teams credentials")
    if service_name not in {"apiserver", "sidekiq"}:
        for key in teams_scope_keys:
            require(key not in environment, f"{service_name} must not receive Teams mappings")
require(
    sidekiq_environment.get("DF_SIDEKIQ_CONCURRENCY") == "5",
    "Sidekiq must receive the validated concurrency value",
)
require(
    2 <= int(sidekiq_environment["DF_SIDEKIQ_CONCURRENCY"]) <= 5,
    "Sidekiq concurrency is outside the ActiveRecord pool bound",
)
for service_name, service in services.items():
    if service_name != "sidekiq":
        require(
            "DF_SIDEKIQ_CONCURRENCY" not in service.get("environment", {}),
            f"{service_name} must not receive Sidekiq concurrency",
        )
for key in live_feature_keys:
    require(
        api_environment[key] == sidekiq_environment[key],
        f"API and Sidekiq must receive the same {key} value",
    )
require(int(api_environment["DF_PPI_MINIMUM_COHORT_SIZE"]) >= 21, "PPI cohort privacy floor is unsafe")
require(
    1 <= int(api_environment["DF_PPI_STALE_AFTER_HOURS"]) <= 48,
    "PPI freshness window is outside the approved range",
)

for service_name in ("migrate", "pdfgen"):
    environment = services[service_name]["environment"]
    for key in live_feature_keys:
        require(key not in environment, f"{service_name} must not receive {key}")

require(
    services["apiserver"]["depends_on"]["migrate"]["condition"] == "service_completed_successfully",
    "API startup must be gated on migrations",
)
require(
    any("/readiness" in argument for argument in services["apiserver"]["healthcheck"]["test"]),
    "API health must check database and Redis readiness",
)
for service_name in ("pdfgen", "sidekiq"):
    require(
        services[service_name]["environment"]["LATEX_BUILD_PATH"]
        == "/texlive/shell/latex_build.sh",
        f"{service_name} must use the TexLive build entry point",
    )
    require(
        services[service_name]["environment"]["DOCKER_HOST"] == "tcp://docker-socket-proxy:2375",
        f"{service_name} must use the constrained Docker API proxy",
    )
    require(
        services[service_name]["depends_on"]["docker-socket-proxy"]["condition"] == "service_healthy",
        f"{service_name} must wait for the Docker API proxy",
    )

require(services["migrate"]["networks"]["egress"]["gw_priority"] == 1, "migrations need deterministic egress")
require(services["apiserver"]["networks"]["edge"]["gw_priority"] == 1, "API needs deterministic egress")
for service_name in ("pdfgen", "sidekiq"):
    require(
        services[service_name]["networks"]["egress"]["gw_priority"] == 1,
        f"{service_name} needs deterministic egress",
    )

require(services["docker-socket-proxy"]["read_only"] is True, "Docker socket proxy filesystem must be read-only")
require("healthcheck" in services["docker-socket-proxy"], "Docker socket proxy must have a health check")
require(
    services["docker-socket-proxy"]["environment"]
    == {"COMPOSE_PROJECT_NAME": compose["name"]},
    "Docker API proxy must not enable broad category ACLs",
)
require(services["jplag"]["network_mode"] == "none", "JPlag must not have network access")
require(services["texlive-pdfgen"]["network_mode"] == "none", "pdfgen TexLive must not have network access")
require(services["texlive-sidekiq"]["network_mode"] == "none", "Sidekiq TexLive must not have network access")

for service_name in ("texlive-pdfgen", "texlive-sidekiq", "jplag"):
    service = services[service_name]
    require(float(service["cpus"]) > 0, f"{service_name} must have a CPU limit")
    require(bool(service["mem_limit"]), f"{service_name} must have a memory limit")
    require(int(service["pids_limit"]) > 0, f"{service_name} must have a PID limit")
    require(service["cap_drop"] == ["ALL"], f"{service_name} must drop Linux capabilities")
    require(
        "no-new-privileges:true" in service["security_opt"],
        f"{service_name} must prevent privilege escalation",
    )

for service_name in ("texlive-pdfgen", "texlive-sidekiq"):
    volume_targets = {volume["target"] for volume in services[service_name]["volumes"]}
    require("/student-work" not in volume_targets, f"{service_name} must not mount student work")

jplag_targets = {volume["target"] for volume in services["jplag"]["volumes"]}
require(
    jplag_targets == {"/student-work/jplag", "/student-work/archive/jplag", "/tmp/jplag"},
    "JPlag must only mount report and temporary paths",
)

for service_name, service in services.items():
    require("@sha256:" in service["image"], f"{service_name} image is not immutable")

print("Compose contract checks passed.")
