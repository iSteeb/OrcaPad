#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 OrcaPad contributors
"""Makes an uploaded build available to an external TestFlight group.

Runs in CI after Distribution/release-testflight.sh uploaded the build:
  1. find the App Store Connect app (bundle id) and the external beta group
  2. wait until the build (version + build number) finished processing
  3. set "What to Test" in the app's primary locale
  4. add the build to the external group
  5. submit the build for Beta App Review
External testers get the build once Apple approves it.

App Store Connect API with a team API key (JWT ES256, signed by openssl);
standard library only. Every API error stops the run with Apple's own error
text. Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (the .p8 contents).
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
WHATS_NEW_LIMIT = 4000  # App Store Connect limit for "What to Test"


class ASCError(Exception):
    pass


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw_signature(der: bytes) -> bytes:
    """ECDSA-Sig-Value (DER SEQUENCE of r, s) -> JOSE r||s, 32 bytes each."""
    if len(der) < 8 or der[0] != 0x30:
        raise ASCError("openssl returned an unexpected signature encoding")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    raw = b""
    for _ in range(2):
        if der[index] != 0x02:
            raise ASCError("openssl returned an unexpected signature encoding")
        length = der[index + 1]
        value = der[index + 2:index + 2 + length].lstrip(b"\x00")
        if len(value) > 32:
            raise ASCError("ECDSA signature integer is longer than 32 bytes")
        raw += value.rjust(32, b"\x00")
        index += 2 + length
    return raw


class Client:
    def __init__(self, key_id: str, issuer_id: str, key_pem: str, key_dir: str):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.key_path = os.path.join(key_dir, "asc-key.p8")
        with open(os.open(self.key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
            f.write(key_pem if key_pem.endswith("\n") else key_pem + "\n")
        self.token = ""
        self.token_expiry = 0

    def jwt(self) -> str:
        now = int(time.time())
        if self.token and now < self.token_expiry - 60:
            return self.token
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        payload = {"iss": self.issuer_id, "iat": now, "exp": now + 1200,
                   "aud": "appstoreconnect-v1"}
        signing_input = (b64url(json.dumps(header, separators=(",", ":")).encode()) + "." +
                         b64url(json.dumps(payload, separators=(",", ":")).encode()))
        signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", self.key_path],
                                input=signing_input.encode(), capture_output=True)
        if signed.returncode != 0:
            raise ASCError(f"openssl could not sign the API token: {signed.stderr.decode()}")
        self.token = signing_input + "." + b64url(der_to_raw_signature(signed.stdout))
        self.token_expiry = now + 1200
        return self.token

    def request(self, method: str, path: str, body: dict | None = None,
                query: dict | None = None) -> dict | None:
        url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(1, 4):
            req = urllib.request.Request(url, data=data, method=method, headers={
                "Authorization": f"Bearer {self.jwt()}",
                "Content-Type": "application/json",
            })
            try:
                with urllib.request.urlopen(req, timeout=60) as response:
                    raw = response.read()
                    return json.loads(raw) if raw else None
            except urllib.error.HTTPError as error:
                detail = error.read().decode(errors="replace")
                # Explicit recovery: Apple's 5xx are transient; anything else is final.
                if error.code >= 500 and attempt < 3:
                    print(f"retrying {method} {path} after HTTP {error.code} (attempt {attempt}/3)")
                    time.sleep(10 * attempt)
                    continue
                raise ASCError(f"{method} {path} -> HTTP {error.code}: {detail}") from None
            except urllib.error.URLError as error:
                if attempt < 3:
                    print(f"retrying {method} {path} after network error {error.reason} (attempt {attempt}/3)")
                    time.sleep(10 * attempt)
                    continue
                raise ASCError(f"{method} {path} -> network error: {error.reason}") from None
        raise ASCError(f"{method} {path}: retries exhausted")


def find_app(client: Client, bundle_id: str) -> dict:
    apps = client.request("GET", "/apps", query={
        "filter[bundleId]": bundle_id, "fields[apps]": "bundleId,name,primaryLocale"})["data"]
    apps = [app for app in apps if app["attributes"]["bundleId"] == bundle_id]
    if len(apps) != 1:
        raise ASCError(f"expected one App Store Connect app for {bundle_id}, found {len(apps)} "
                       "(create it: App Store Connect > Apps > + > New App)")
    return apps[0]


def find_external_group(client: Client, app_id: str, name: str) -> dict:
    groups = client.request("GET", "/betaGroups", query={
        "filter[app]": app_id, "filter[name]": name,
        "fields[betaGroups]": "name,isInternalGroup"})["data"]
    groups = [group for group in groups if group["attributes"]["name"] == name]
    if len(groups) != 1:
        raise ASCError(f"expected one TestFlight group named {name!r}, found {len(groups)} "
                       "(create an external group in App Store Connect > TestFlight)")
    if groups[0]["attributes"]["isInternalGroup"]:
        raise ASCError(f"TestFlight group {name!r} is internal; external testing needs an external group")
    return groups[0]


def wait_for_build(client: Client, app_id: str, version: str, build: str, timeout: int) -> dict:
    deadline = time.time() + timeout
    while True:
        builds = client.request("GET", "/builds", query={
            "filter[app]": app_id, "filter[version]": build,
            "filter[preReleaseVersion.version]": version,
            "fields[builds]": "version,processingState,expired"})["data"]
        if builds:
            state = builds[0]["attributes"]["processingState"]
            print(f"build {version} ({build}): {state}")
            if state == "VALID":
                return builds[0]
            if state in ("FAILED", "INVALID"):
                raise ASCError(f"App Store Connect processing ended {state} for {version} ({build}); "
                               "see the email from App Store Connect for the reason")
        else:
            print(f"build {version} ({build}) is not visible in App Store Connect yet")
        if time.time() > deadline:
            raise ASCError(f"timed out after {timeout}s waiting for {version} ({build}) to process")
        time.sleep(30)


def set_whats_new(client: Client, build_id: str, locale: str, text: str) -> None:
    text = text.strip()
    if not text:
        raise ASCError("the release notes ('What to Test') are empty")
    if len(text) > WHATS_NEW_LIMIT:
        text = text[:WHATS_NEW_LIMIT - 2].rstrip() + "\n…"
    existing = client.request("GET", f"/builds/{build_id}/betaBuildLocalizations")["data"]
    match = [loc for loc in existing if loc["attributes"]["locale"] == locale]
    if match:
        client.request("PATCH", f"/betaBuildLocalizations/{match[0]['id']}", body={"data": {
            "type": "betaBuildLocalizations", "id": match[0]["id"],
            "attributes": {"whatsNew": text}}})
    else:
        client.request("POST", "/betaBuildLocalizations", body={"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": locale, "whatsNew": text},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    print(f"'What to Test' set ({locale}, {len(text)} characters)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--build", required=True, help="CFBundleVersion")
    parser.add_argument("--group", required=True, help="external TestFlight group name")
    parser.add_argument("--notes-file", required=True, help="'What to Test' text")
    parser.add_argument("--timeout", type=int, default=3600, help="processing wait, seconds")
    args = parser.parse_args()

    missing = [name for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8") if not os.environ.get(name)]
    if missing:
        raise ASCError(f"missing environment: {', '.join(missing)}")
    with open(args.notes_file, encoding="utf-8") as f:
        notes = f.read()

    with tempfile.TemporaryDirectory() as key_dir:
        client = Client(os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"],
                        os.environ["ASC_KEY_P8"], key_dir)
        app = find_app(client, args.bundle_id)
        locale = app["attributes"]["primaryLocale"]
        print(f"app {app['attributes']['name']} ({app['id']}), primary locale {locale}")
        group = find_external_group(client, app["id"], args.group)
        build = wait_for_build(client, app["id"], args.version, args.build, args.timeout)
        set_whats_new(client, build["id"], locale, notes)
        client.request("POST", f"/betaGroups/{group['id']}/relationships/builds",
                       body={"data": [{"type": "builds", "id": build["id"]}]})
        print(f"added to external group {args.group!r}")
        client.request("POST", "/betaAppReviewSubmissions", body={"data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
        print(f"submitted {args.version} ({args.build}) for Beta App Review; "
              "external testers get it once Apple approves")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ASCError as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
