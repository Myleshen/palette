#!/usr/bin/env python3
"""Minimal Palette external provider.

Copy this folder to ~/.config/palette/providers/hello, make main.py executable
if needed, then press Cmd-R in Palette. Type "/hello" to reach it.
"""

import json
import sys


def send(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except json.JSONDecodeError:
        continue

    kind = message.get("type")
    if kind == "init":
        continue
    if kind == "query":
        query = message.get("text", "")
        send({
            "type": "results",
            "id": message.get("id"),
            "items": [{
                "id": "hello",
                "title": "Hello from " + (query or "Palette"),
                "subtitle": "An external NDJSON provider",
                "icon": {"type": "symbol", "value": "hand.wave"},
                "actions": [{
                    "id": "say-hello",
                    "title": "Say Hello",
                    "kind": "custom",
                }],
            }],
        })
        send({"type": "done", "id": message.get("id")})
    elif kind == "activate":
        send({"type": "notify", "message": "Hello from the example provider"})
    elif kind == "shutdown":
        break
