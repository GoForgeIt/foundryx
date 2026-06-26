import jwt, time, json, urllib.request, urllib.error, sys
KEY_ID="TY9TX3FBAD"; ISSUER="6515707a-bc3b-4391-a626-8997a04d3afa"
KEY=open("/Users/nicholasrinard/.appstoreconnect/private_keys/AuthKey_TY9TX3FBAD.p8").read()
tok=jwt.encode({"iss":ISSUER,"iat":int(time.time()),"exp":int(time.time())+1200,"aud":"appstoreconnect-v1"},
               KEY, algorithm="ES256", headers={"kid":KEY_ID,"typ":"JWT"})
def get(path):
    r=urllib.request.Request("https://api.appstoreconnect.apple.com"+path, headers={"Authorization":f"Bearer {tok}"})
    try: return json.load(urllib.request.urlopen(r, timeout=30))
    except urllib.error.HTTPError as e: return {"_error":e.code,"_body":e.read().decode()[:300]}

b57="1b492f48-d224-453a-8f28-c19bff4051cc"; b56="c269ad4b-1529-4c0a-bd70-bdcf41dbb2f5"
print("=== probe crash endpoints (builds 57 & 56) ===")
for label,bid in [("57",b57),("56",b56)]:
    for ep in [f"/v1/builds/{bid}/diagnosticSignatures?limit=10",
               f"/v1/betaFeedbackCrashSubmissions?filter[build]={bid}&limit=10"]:
        r=get(ep); name=ep.split('?')[0].split('/')[-1]
        if "_error" in r:
            print(f"  build {label}  {name:28s} -> HTTP {r['_error']}: {r['_body'][:120]}")
        else:
            data=r.get("data",[])
            print(f"  build {label}  {name:28s} -> {len(data)} items")
            for d in data[:8]:
                a=d.get("attributes",{})
                print("      ", d["type"], json.dumps(a)[:220])

# Also the account-wide latest crash submissions (any build), newest first
print("\n=== latest crash submissions across the app (any build) ===")
r=get("/v1/betaFeedbackCrashSubmissions?sort=-createdDate&limit=10")
if "_error" in r: print("  ", r["_error"], r["_body"][:200])
else:
    for d in r.get("data",[])[:10]:
        a=d.get("attributes",{})
        print("  ", a.get("createdDate","?")[:19], "device=",a.get("deviceModel","?"), "os=",a.get("osVersion","?"), "id=",d["id"])
