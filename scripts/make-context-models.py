#!/usr/bin/env python3
"""Rebuilds Resources/AgentContextModels.deflate from a full capacity catalog.

The app ships a capacity-only snapshot of the Oh My Pi model catalog
(https://github.com/can1357/oh-my-pi/blob/main/packages/catalog/src/models.json).
Two reductions keep it small, both without losing a lookup:

  * a model every provider agrees on becomes one bare key (`gpt-4o`: 128000);
  * a model providers disagree on keeps one `provider/model` key each, so a
    provider-specific lookup is exact and an unqualified one still refuses;
  * ids that themselves contain a slash (`deepseek-ai/deepseek-v4-flash`) stay
    provider-qualified, since a bare key for them would collide with that slash
    form used as a provider/model pair.

The result is written as a raw DEFLATE stream (what a .gz holds, minus the
container), because Apple's Compression framework reads that directly and
cannot read the gzip wrapper.

Usage:
  scripts/make-context-models.py [catalog.json]

With no argument, the current file's `source` URL is downloaded (falling back to
the upstream URL). Run from anywhere; paths are resolved from the repository.

Regenerate the file, then rebuild the app so the bundle picks it up.
"""

import json
import pathlib
import sys
import urllib.request
import zlib

UPSTREAM = "https://github.com/can1357/oh-my-pi/blob/main/packages/catalog/src/models.json"
RAW = "https://raw.githubusercontent.com/can1357/oh-my-pi/main/packages/catalog/src/models.json"
OUT = pathlib.Path(__file__).resolve().parent.parent / "Resources/AgentContextModels.deflate"


def fold(models):
    """Collapses a provider/model catalog into bare keys where every provider agrees.

    Ids that contain a slash stay provider-qualified: a bare key like
    `anthropic/claude-sonnet-4-5` would otherwise collide with the qualified key of
    `claude-sonnet-4-5` on provider `anthropic`, silently changing a real lookup.
    """
    by_model = {}
    for key, capacity in models.items():
        provider, _, model = key.partition("/")
        by_model.setdefault(model or key, {})[provider] = capacity
    folded = {}
    for model, capacities in by_model.items():
        if "/" not in model and len(set(capacities.values())) == 1:
            folded[model] = next(iter(capacities.values()))
        else:
            for provider, capacity in capacities.items():
                folded[f"{provider}/{model}"] = capacity
    return folded


def load():
    if len(sys.argv) > 1:
        return json.loads(pathlib.Path(sys.argv[1]).read_text())
    if OUT.exists():
        current = json.loads(zlib.decompress(OUT.read_bytes(), -15))
        source = current.get("source", RAW)
    else:
        source, current = RAW, {}
    url = RAW if source == UPSTREAM else source
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


def main():
    catalog = load()
    models = catalog["models"]
    folded = fold(models)
    payload = {
        "source": catalog.get("source", UPSTREAM),
        "retrieved": catalog.get("retrieved"),
        "note": "Bare keys are models every provider agrees on; provider/model keys disagree.",
        "models": folded,
    }
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    # Raw DEFLATE: what a .gz holds without its container, which Apple's decoder needs.
    encoder = zlib.compressobj(9, zlib.DEFLATED, -15)
    OUT.write_bytes(encoder.compress(raw) + encoder.flush())
    print(
        f"{len(models)} entries → {len(folded)} · {len(raw) / 1024:.0f} KB JSON → "
        f"{OUT.stat().st_size / 1024:.0f} KB deflate"
    )


if __name__ == "__main__":
    main()
