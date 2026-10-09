#!/usr/bin/env python3
"""Read-only category shape probe. Never print or save account credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import tempfile
import time

import requests


def refresh_session(path, credentials, headers):
    """Renew the same persisted device, matching the plugin's login flow."""
    timestamp = int(time.time() * 1000)
    random_value = random.randint(0, 999)
    device_id = credentials["device_id"]
    signature = hashlib.sha256(f"{timestamp}{device_id}{random_value}".encode()).hexdigest()
    login_headers = {key: value for key, value in headers.items() if key != "accessToken"}
    login_headers["Content-Type"] = "application/json;charset=UTF-8"
    response = requests.post("https://i.weread.qq.com/login", headers=login_headers, json={
        "refreshToken": credentials["refresh_token"], "deviceId": device_id, "deviceName": "BOOX",
        "timestamp": timestamp, "random": random_value, "signature": signature, "deviceType": 3,
    }, timeout=30)
    print("POST /login HTTP", response.status_code)
    response.raise_for_status()
    renewed = response.json()
    if not renewed.get("accessToken"):
        raise RuntimeError("session refresh returned no access token; errcode=" + str(renewed.get("errcode")))
    credentials["access_token"] = renewed["accessToken"]
    if renewed.get("refreshToken"):
        credentials["refresh_token"] = renewed["refreshToken"]
    credentials["login_time"] = str(int(time.time()))
    descriptor, temporary = tempfile.mkstemp(prefix=".category-session-", dir=Path(path).parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(credentials, output, ensure_ascii=False)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print("Existing device session renewed and saved (0600)")
    return credentials["access_token"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials", required=True, help="Existing eink session JSON; renewed on HTTP 401")
    parser.add_argument("--fixture", required=True, help="Sanitized public category metadata output")
    parser.add_argument("--lua-fixture", help="Optional equivalent fixture for standalone Lua specs")
    args = parser.parse_args()
    credentials = json.loads(Path(args.credentials).read_text())
    headers = {
        "User-Agent": "WeRead/2.1.2 WRBrand/Onyx wr_eink Dalvik/2.1.0 (Linux; U; Android 11; BOOX Build/onyx)",
        "Accept": "*/*", "appver": "2.1.2.10245900", "basever": "2.1.2.10245900",
        "baseapi": "30", "osver": "11", "channelId": "900",
        "vid": str(credentials["vid"]), "accessToken": credentials["access_token"],
    }
    response = requests.get("https://i.weread.qq.com/category/list", headers=headers, timeout=20)
    print("GET /category/list HTTP", response.status_code)
    if response.status_code == 401:
        headers["accessToken"] = refresh_session(args.credentials, credentials, headers)
        response = requests.get("https://i.weread.qq.com/category/list", headers=headers, timeout=20)
        print("GET /category/list after renewal HTTP", response.status_code)
    response.raise_for_status()
    raw = response.json()
    if raw.get("errcode"):
        raise RuntimeError("category/list errcode=" + str(raw["errcode"]))
    fields = ("categoryId", "CategoryId", "title", "totalCount", "level", "parentCategoryId")
    fixture = {
        key: [{field: node[field] for field in fields if field in node}
              for node in raw.get(key, [])]
        for key in ("novelCategories", "categories")
    }
    Path(args.fixture).write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n")
    nodes = {}
    for key, entries in fixture.items():
        print(key, "count=", len(entries))
        for node in entries:
            nodes.setdefault(str(node.get("categoryId", node.get("CategoryId", ""))), node)
    roots = [node for node in nodes.values() if str(node.get("parentCategoryId", "")) in ("", "0")]
    old_groups = []
    omitted = []
    for root in roots:
        root_id = str(root.get("categoryId", root.get("CategoryId", "")))
        children = [node for node in nodes.values() if str(node.get("parentCategoryId", "")) == root_id]
        print("ROOT", root["title"], "id=", root_id, "children=", len(children))
        (old_groups if children else omitted).append(root["title"])
    print("Existing nonempty-only groups:", ", ".join(old_groups))
    print("Omitted leaf roots:", ", ".join(omitted))
    print("Unique category IDs:", len(nodes))
    # Prototype the lossless tree contract before changing the Lua parser.
    root_ids = {str(node.get("categoryId", node.get("CategoryId", ""))) for node in roots}
    represented = root_ids | {
        node_id for node_id, node in nodes.items()
        if str(node.get("parentCategoryId", "")) in root_ids
    }
    assert represented == set(nodes), "category tree has unattached descendants"
    print("Lossless root-plus-children prototype:", len(represented), "of", len(nodes), "IDs covered")
    if args.lua_fixture:
        lines = ["-- Public /category/list metadata captured 2026-10-09; no account or book content.", "return {"]
        for key, entries in fixture.items():
            lines.append("    " + key + " = {")
            for node in entries:
                values = [field + " = " + json.dumps(value, ensure_ascii=False) for field, value in node.items()]
                lines.append("        { " + ", ".join(values) + " },")
            lines.append("    },")
        lines.append("}")
        path = Path(args.lua_fixture)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
