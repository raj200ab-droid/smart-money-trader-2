#!/usr/bin/env python3
"""
fetch_history.py — download Deriv tick/candle history for offline work.

Default: 180s (3-min) grains, 30000 samples, fetched in 2880-sample chunks.

    python3 fetch_history.py --symbol R_100 --grains 180 --samples 30000
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

CHUNK = 2880
GRAIN_TO_GRAN = {"1440": 86400, "900": 900, "300": 300, "180": 180, "60": 60}


async def fetch(symbol: str, grains: str, samples: int, token: str) -> list:
    import websockets
    gran = GRAIN_TO_GRAN.get(str(grains), 180)
    end = "latest"
    out = []
    while len(out) < samples:
        count = min(CHUNK, samples - len(out))
        async with websockets.connect(
                f"wss://ws.derivws.com/websockets/v3?app_id={os.environ.get('DERIV_APP_ID', '1089')}"
        ) as ws:
            if token:
                await ws.send(json.dumps({"authorize": token}))
                await ws.recv()
            await ws.send(json.dumps({"ticks_history": symbol, "style": "candles",
                                      "granularity": gran, "count": count, "end": end}))
            data = json.loads(await ws.recv())
        candles = data.get("candles", [])
        if not candles:
            break
        out = candles + out
        end = str(candles[0]["epoch"] - 1)
    return out[-samples:]


def main(argv=None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--symbol", default="R_100")
    p.add_argument("--grains", default="180", choices=["1440", "900", "300", "180", "60"])
    p.add_argument("--samples", type=int, default=30000)
    p.add_argument("--out", default="")
    args = p.parse_args(argv)
    candles = asyncio.get_event_loop().run_until_complete(
        fetch(args.symbol, args.grains, args.samples, os.environ.get("DERIV_TOKEN", "")))
    out = args.out or f"{args.symbol}_{args.grains}s.json"
    with open(out, "w") as f:
        json.dump(candles, f)
    print(json.dumps({"saved": out, "candles": len(candles)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
