#!/usr/bin/env python3
"""Fetch the crash log for a TestFlight betaFeedbackCrashSubmission once Apple attaches it.

Usage: python3 scripts/fetch-latest-crash.py [submission_id]
Defaults to the newest submission on the FoundryX app. Exits 0 + prints SAVED when the
log is downloaded (to /tmp/foundryx_crash_<id>.ips); exits 3 while still unattached.
"""
import jwt, time, json, sys, urllib.request, urllib.error

KEY_ID = "TY9TX3FBAD"
ISSUER = "6515707a-bc3b-4391-a626-8997a04d3afa"
APP_ID = "6775204140"  # com.goforgeit.foundryx
KEY = open("/Users/nicholasrinard/.appstoreconnect/private_keys/AuthKey_TY9TX3FBAD.p8").read()


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER, "iat": now - 30, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        KEY, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"},
    )


def get(path, tok):
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path,
        headers={"Authorization": f"Bearer {tok}"},
    )
    try:
        return json.load(urllib.request.urlopen(req, timeout=30)), None
    except urllib.error.HTTPError as e:
        return None, f"{e.code}: {e.read().decode()[:200]}"


def main():
    tok = token()
    cid = sys.argv[1] if len(sys.argv) > 1 else None
    if not cid:
        subs, err = get(f"/v1/apps/{APP_ID}/betaFeedbackCrashSubmissions?sort=-createdDate&limit=1", tok)
        if err:
            print("list ERR", err); sys.exit(1)
        data = subs.get("data", [])
        if not data:
            print("no crash submissions"); sys.exit(1)
        cid = data[0]["id"]
        print("newest submission:", cid, data[0].get("attributes", {}).get("createdDate", "?"))

    d, err = get(f"/v1/betaFeedbackCrashSubmissions/{cid}/crashLog", tok)
    if err:
        print("crash log not attached yet:", err.split(":")[0]); sys.exit(3)
    attrs = d.get("data", {}).get("attributes", {})
    url = attrs.get("downloadUrl") or attrs.get("logUrl")
    if not url:
        print("attached but no download url:", json.dumps(attrs)[:300]); sys.exit(3)
    body = urllib.request.urlopen(url, timeout=60).read().decode(errors="replace")
    out = f"/tmp/foundryx_crash_{cid[:8]}.ips"
    open(out, "w").write(body)
    print("SAVED", out, len(body), "bytes")


if __name__ == "__main__":
    main()
