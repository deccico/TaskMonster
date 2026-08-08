#!/usr/bin/env python3
"""Recreate and install the "Task Monster App Store" provisioning profile.

The release Mac has no Apple ID signed into Xcode.app, so nothing can renew
signing material through the UI. Provisioning profiles are deleted by Apple
whenever the distribution certificate they reference is revoked (that happened
to team 76UL6RCLTT on 28 Jul 2026), which breaks the *export* step of a release
long after the archive has been built. This mints a fresh App Store profile for
the current distribution certificate over the App Store Connect API and drops it
where xcodebuild looks for it.

    python3 scripts/mint_ios_profile.py            # create (fails if it exists)
    python3 scripts/mint_ios_profile.py --replace  # delete the old one first

Auth: an App Store Connect API key with Admin or App Manager role. Key id and
issuer come from ASC_KEY_ID / ASC_ISSUER_ID (defaults below), with the matching
AuthKey_<ASC_KEY_ID>.p8 in ~/.appstoreconnect/private_keys/.

Note the profile is matched **by name** in ios/ExportOptions.plist — keep
PROFILE_NAME and that file in sync.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

KEY_ID = os.environ.get("ASC_KEY_ID", "PVV887QV57")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "1623d92a-9373-42ee-8bca-9435f6df7f4d")
KEY_PATH = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
BASE = "https://api.appstoreconnect.apple.com"

BUNDLE_ID = "com.darumatic.taskMonster"
PROFILE_NAME = "Task Monster App Store"
PROFILE_TYPE = "IOS_APP_STORE"
PROFILE_DIR = os.path.expanduser(
    "~/Library/Developer/Xcode/UserData/Provisioning Profiles"
)


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _der_to_raw(der: bytes) -> bytes:
    """DER ECDSA signature -> the raw r||s pair JWS wants."""
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 3 + (der[1] & 0x7F) - 1
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        length = der[i + 1]
        out += der[i + 2 : i + 2 + length].lstrip(b"\x00").rjust(32, b"\x00")
        i += 2 + length
    return out


def jwt_parts(now: int, key_id: str, issuer_id: str) -> str:
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + 1200,
               "aud": "appstoreconnect-v1"}
    return (_b64url(json.dumps(header).encode()) + "."
            + _b64url(json.dumps(payload).encode()))


def token() -> str:
    signing_input = jwt_parts(int(time.time()), KEY_ID, ISSUER_ID)
    # openssl keeps this dependency-free; the .p8 is an EC private key.
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as handle:
        handle.write(signing_input.encode())
        msg_path = handle.name
    try:
        der = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", KEY_PATH, msg_path],
            capture_output=True, check=True).stdout
    finally:
        os.unlink(msg_path)
    return signing_input + "." + _b64url(_der_to_raw(der))


def request(method: str, path: str, body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token())
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        raw = err.read()
        try:
            return err.code, json.loads(raw)
        except ValueError:
            return err.code, raw.decode(errors="replace")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def get_all(path: str):
    status, resp = request("GET", path)
    if status != 200:
        fail(f"GET {path} -> {status}: {resp}")
    return (resp or {}).get("data", [])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true",
                        help=f"delete an existing {PROFILE_NAME!r} profile first")
    args = parser.parse_args()

    if not os.path.exists(KEY_PATH):
        fail(f"no API key at {KEY_PATH} (set ASC_KEY_ID / ASC_ISSUER_ID)")

    certs = get_all(
        "/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=50"
    )
    if not certs:
        fail("the team has no Apple Distribution certificate — mint one first")
    if len(certs) > 1:
        print(f"NOTE: {len(certs)} distribution certificates; using the one that "
              "expires last")
    cert = max(certs, key=lambda c: c["attributes"]["expirationDate"])
    print(f"==> certificate {cert['id']} "
          f"serial={cert['attributes']['serialNumber']} "
          f"expires {cert['attributes']['expirationDate']}")

    # The export signs with the identity in the login keychain, so a profile
    # built against any other certificate would fail at export time.
    keychain = subprocess.run(
        ["security", "find-certificate", "-c",
         "Apple Distribution: DARUMATIC PTY LTD", "-p"],
        capture_output=True, text=True)
    if keychain.returncode == 0:
        serial = subprocess.run(
            ["openssl", "x509", "-noout", "-serial"],
            input=keychain.stdout, capture_output=True, text=True,
        ).stdout.strip().partition("=")[2]
        if serial.upper() != cert["attributes"]["serialNumber"].upper():
            fail(f"keychain identity (serial {serial}) is not the certificate "
                 f"this profile would use ({cert['attributes']['serialNumber']}) "
                 "— import the matching .p12 or revoke the stale certificate")
    else:
        print("NOTE: no 'Apple Distribution: DARUMATIC PTY LTD' identity in the "
              "keychain — the profile is created but the export will fail "
              "until it is imported")

    bundles = get_all(f"/v1/bundleIds?filter[identifier]={BUNDLE_ID}")
    if not bundles:
        fail(f"no bundle id resource for {BUNDLE_ID}")
    bundle = bundles[0]
    print(f"==> bundle id {bundle['id']} ({BUNDLE_ID})")

    existing = [p for p in get_all("/v1/profiles?limit=200")
                if p["attributes"]["name"] == PROFILE_NAME]
    if existing:
        if not args.replace:
            fail(f"{PROFILE_NAME!r} already exists ({existing[0]['id']}) — "
                 "pass --replace to recreate it")
        for profile in existing:
            status, resp = request("DELETE", f"/v1/profiles/{profile['id']}")
            if status not in (200, 204):
                fail(f"could not delete {profile['id']}: {status} {resp}")
            print(f"==> deleted stale profile {profile['id']}")

    status, resp = request("POST", "/v1/profiles", {
        "data": {
            "type": "profiles",
            "attributes": {"name": PROFILE_NAME, "profileType": PROFILE_TYPE},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                "certificates": {
                    "data": [{"type": "certificates", "id": cert["id"]}]
                },
            },
        }
    })
    if status not in (200, 201):
        fail(f"POST /v1/profiles -> {status}: {resp}")

    attrs = resp["data"]["attributes"]
    os.makedirs(PROFILE_DIR, exist_ok=True)
    dest = os.path.join(PROFILE_DIR, f"{attrs['uuid']}.mobileprovision")
    with open(dest, "wb") as handle:
        handle.write(base64.b64decode(attrs["profileContent"]))
    print(f"==> created {PROFILE_NAME!r} ({attrs['profileState']}, expires "
          f"{attrs['expirationDate']})")
    print(f"==> installed {dest}")


if __name__ == "__main__":
    main()
