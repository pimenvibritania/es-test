#!/usr/bin/env python3
"""
Pritunl REST API provisioning helper.

Runs on the Ansible control node (delegate_to: localhost) against the
Pritunl admin API over its public IP. Idempotent: looks up existing
organization/server/user by name before creating.

Auth: Pritunl's HMAC-SHA256 request signing scheme (Auth-Token /
Auth-Timestamp / Auth-Nonce / Auth-Signature headers). There's no official
Python SDK for this, so it's implemented directly per Pritunl's documented
scheme -- same technique used to validate this manually before wiring it
into Ansible.

Reads PRITUNL_API_TOKEN / PRITUNL_API_SECRET from the environment (kept out
of argv/history). Prints a single JSON object to stdout on success.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import uuid

import requests
import urllib3

urllib3.disable_warnings()


def pritunl_request(base_url, token, secret, method, path, body=None):
    auth_timestamp = str(int(time.time()))
    auth_nonce = uuid.uuid4().hex
    auth_string = "&".join([token, auth_timestamp, auth_nonce, method.upper(), path])
    auth_signature = base64.b64encode(
        hmac.new(secret.encode(), auth_string.encode(), hashlib.sha256).digest()
    )
    headers = {
        "Auth-Token": token,
        "Auth-Timestamp": auth_timestamp,
        "Auth-Nonce": auth_nonce,
        "Auth-Signature": auth_signature,
        "Content-Type": "application/json",
    }
    return requests.request(
        method, base_url + path, headers=headers, json=body, verify=False, timeout=15
    )


def find_by_name(items, name):
    for item in items:
        if item.get("name") == name:
            return item
    return None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", required=True)
    p.add_argument("--org-name", required=True)
    p.add_argument("--server-name", required=True)
    p.add_argument("--server-port", type=int, required=True)
    p.add_argument("--server-protocol", default="udp")
    p.add_argument("--server-network", required=True)
    p.add_argument("--user-name", required=True)
    args = p.parse_args()

    token = os.environ["PRITUNL_API_TOKEN"]
    secret = os.environ["PRITUNL_API_SECRET"]
    base = args.base_url

    def req(method, path, body=None):
        r = pritunl_request(base, token, secret, method, path, body)
        if r.status_code not in (200,):
            print(
                json.dumps({"error": True, "path": path, "status": r.status_code, "body": r.text}),
                file=sys.stderr,
            )
            sys.exit(1)
        return r.json()

    # 1. Organization (idempotent lookup)
    orgs = req("GET", "/organization")
    org = find_by_name(orgs, args.org_name)
    if not org:
        org = req("POST", "/organization", {"name": args.org_name})
    org_id = org["id"]

    # 2. Server (idempotent lookup)
    servers = req("GET", "/server")
    server = find_by_name(servers, args.server_name)
    if not server:
        server = req(
            "POST",
            "/server",
            {
                "name": args.server_name,
                "port": args.server_port,
                "protocol": args.server_protocol,
                "network": args.server_network,
                "dns_servers": ["8.8.8.8"],
                # aes128/sha256 are required explicitly -- the API 400s
                # ("cipher_invalid" / "hash_invalid") without them.
                "cipher": "aes128",
                "hash": "sha256",
            },
        )
    server_id = server["id"]

    # 3. Attach organization to server (idempotent -- PUT is safe to repeat)
    req("PUT", f"/server/{server_id}/organization/{org_id}")

    # 4. User (idempotent lookup within org)
    users = req("GET", f"/user/{org_id}")
    user = find_by_name(users, args.user_name)
    if not user:
        created = req("POST", f"/user/{org_id}", {"name": args.user_name})
        user = created[0] if isinstance(created, list) else created
    user_id = user["id"]

    # 5. Start server if not already online
    server_status = req("GET", f"/server/{server_id}")
    if server_status.get("status") != "online":
        req("PUT", f"/server/{server_id}/operation/start")

    # 6. Download the client .ovpn profile.
    # NOTE: the documented-looking `/key/<org>/<user>.key` endpoint 500s on
    # this Pritunl version (server-side bug: `key_id = key_id[:128]` on an
    # ObjectId, not a str -- confirmed via /var/log/pritunl.log). The route
    # that actually works is `/data/<org_id>/<user_id>/<server_id>.key`,
    # found by grepping handlers/key.py on the instance for @app.route.
    r = pritunl_request(
        base, token, secret, "GET", f"/data/{org_id}/{user_id}/{server_id}.key"
    )
    if r.status_code != 200:
        print(
            json.dumps({"error": True, "path": "download_profile", "status": r.status_code}),
            file=sys.stderr,
        )
        sys.exit(1)
    ovpn_profile_b64 = base64.b64encode(r.content).decode()

    print(
        json.dumps(
            {
                "org_id": org_id,
                "server_id": server_id,
                "user_id": user_id,
                "ovpn_profile_b64": ovpn_profile_b64,
            }
        )
    )


if __name__ == "__main__":
    main()
