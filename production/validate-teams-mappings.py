#!/usr/bin/env python3
"""Validate the optional mapping configuration without printing its contents."""

import json
import re
import sys

GUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
CHANNEL = re.compile(r"19:[A-Za-z0-9_-]+@thread\.(?:tacv2|skype)")


def valid_guid(value):
    return isinstance(value, str) and GUID.fullmatch(value)


def validate():
    raw = sys.stdin.read(100_001)
    if len(raw.encode("utf-8")) > 100_000:
        return False
    mappings = json.loads(raw)
    minimum = 1 if sys.argv[1] == "true" else 0
    if not isinstance(mappings, list) or not minimum <= len(mappings) <= 20:
        return False
    identities = set()
    for mapping in mappings:
        if not isinstance(mapping, dict):
            return False
        unit = mapping.get("unit_id")
        team = mapping.get("team_id")
        channel = mapping.get("channel_id")
        publishers = mapping.get("publisher_ids")
        if not (
            type(unit) is int and unit > 0
            and valid_guid(team)
            and isinstance(channel, str) and len(channel) <= 256
            and CHANNEL.fullmatch(channel)
            and mapping.get("student_visible") is True
            and isinstance(publishers, list) and 1 <= len(publishers) <= 100
            and all(valid_guid(publisher) for publisher in publishers)
        ):
            return False
        identity = (unit, team.lower(), channel)
        if identity in identities:
            return False
        identities.add(identity)
    return True


try:
    accepted = validate()
except (ValueError, TypeError, KeyError, IndexError):
    accepted = False
if not accepted:
    raise SystemExit("Use up to 20 unique unit/channel mappings, each explicitly student-visible with approved staff publisher IDs; enabled import needs at least one mapping.")
