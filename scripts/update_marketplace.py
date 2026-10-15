#!/usr/bin/env python3
"""Adds or updates a plugin entry in a Claude plugin marketplace.json.

usage: update_marketplace.py MARKETPLACE_JSON PLUGIN_JSON SOURCE
"""
import json
import os
import sys

DEFAULT_MARKETPLACE = {
    "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
    "name": "agentic-marketplace",
    "description": "Claude plugins by Victor Wolf",
    "owner": {"name": "Victor Wolf", "url": "https://github.com/VictorW96"},
    "plugins": [],
}


def main(marketplace_path: str, plugin_path: str, source: str) -> None:
    with open(plugin_path, encoding="utf-8") as f:
        plugin = json.load(f)

    if os.path.exists(marketplace_path):
        with open(marketplace_path, encoding="utf-8") as f:
            marketplace = json.load(f)
    else:
        marketplace = json.loads(json.dumps(DEFAULT_MARKETPLACE))

    entry = {
        "name": plugin["name"],
        "source": source,
        "description": plugin.get("description", ""),
        "version": plugin["version"],
        "author": plugin.get("author"),
        "homepage": plugin.get("homepage"),
        "repository": plugin.get("repository"),
        "license": plugin.get("license"),
        "keywords": plugin.get("keywords"),
        "category": "productivity",
    }
    entry = {k: v for k, v in entry.items() if v is not None}

    plugins = marketplace.setdefault("plugins", [])
    for i, existing in enumerate(plugins):
        if existing.get("name") == entry["name"]:
            plugins[i] = {**existing, **entry}
            break
    else:
        plugins.append(entry)
    plugins.sort(key=lambda p: p["name"])

    with open(marketplace_path, "w", encoding="utf-8") as f:
        json.dump(marketplace, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"Updated {marketplace_path}: {entry['name']} {entry['version']}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
