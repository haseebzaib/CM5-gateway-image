#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import time
from collections import deque
from pathlib import Path
from typing import Any


BASE_DIR = Path("/opt/gateway")
OBS_DIR = BASE_DIR / "system_related" / "observability"
STATE_DIR = OBS_DIR / "state"
CURRENT_FILE = STATE_DIR / "metrics_current.json"
HISTORY_FILE = STATE_DIR / "metrics_history.json"
SAMPLE_INTERVAL = 5.0
MAX_HISTORY = 120
NETWORK_INTERFACES = ("eth0", "wlan0")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def write_json(path: Path, payload: dict[str, Any]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    tmp.replace(path)


def cpu_snapshot() -> tuple[list[int], list[list[int]]]:
    lines = Path("/proc/stat").read_text(encoding="utf-8").splitlines()
    total: list[int] | None = None
    per_core: list[list[int]] = []
    for line in lines:
        if not line.startswith("cpu"):
            continue
        parts = line.split()
        values = [int(value) for value in parts[1:]]
        if parts[0] == "cpu":
            total = values
        elif parts[0].startswith("cpu") and parts[0][3:].isdigit():
            per_core.append(values)
    return total or [0] * 10, per_core


def cpu_percent(previous: list[int], current: list[int]) -> float:
    prev_idle = previous[3] + previous[4]
    cur_idle = current[3] + current[4]
    prev_total = sum(previous)
    cur_total = sum(current)
    total_delta = cur_total - prev_total
    idle_delta = cur_idle - prev_idle
    if total_delta <= 0:
        return 0.0
    return round(max(0.0, 100.0 * (1.0 - (idle_delta / total_delta))), 2)


def meminfo() -> dict[str, Any]:
    values: dict[str, int] = {}
    for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
        key, raw = line.split(":", 1)
        number = int(raw.strip().split()[0]) * 1024
        values[key] = number

    mem_total = values.get("MemTotal", 0)
    mem_available = values.get("MemAvailable", 0)
    swap_total = values.get("SwapTotal", 0)
    swap_free = values.get("SwapFree", 0)
    mem_used = max(0, mem_total - mem_available)
    swap_used = max(0, swap_total - swap_free)
    return {
        "memory_bytes": {
            "total": mem_total,
            "used": mem_used,
            "available": mem_available,
            "used_percent": round((mem_used / mem_total) * 100, 2) if mem_total else 0.0,
        },
        "swap_bytes": {
            "total": swap_total,
            "used": swap_used,
            "free": swap_free,
            "used_percent": round((swap_used / swap_total) * 100, 2) if swap_total else 0.0,
        },
    }


def temperature_c() -> float | None:
    thermal = Path("/sys/class/thermal/thermal_zone0/temp")
    if not thermal.exists():
        return None
    try:
        return round(int(read_text(thermal)) / 1000.0, 2)
    except (OSError, ValueError):
        return None


def load_average() -> dict[str, float]:
    one, five, fifteen = os.getloadavg()
    return {"1m": round(one, 2), "5m": round(five, 2), "15m": round(fifteen, 2)}


def network_totals() -> dict[str, dict[str, int]]:
    result: dict[str, dict[str, int]] = {}
    for iface in NETWORK_INTERFACES:
        base = Path("/sys/class/net") / iface / "statistics"
        if not base.exists():
            continue
        try:
            result[iface] = {
                "rx_bytes": int(read_text(base / "rx_bytes")),
                "tx_bytes": int(read_text(base / "tx_bytes")),
            }
        except (OSError, ValueError):
            continue
    return result


def filesystem_usage() -> dict[str, int | float]:
    usage = shutil.disk_usage("/")
    used = usage.total - usage.free
    return {
        "total_bytes": usage.total,
        "used_bytes": used,
        "free_bytes": usage.free,
        "used_percent": round((used / usage.total) * 100, 2) if usage.total else 0.0,
    }


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    previous_total, previous_cores = cpu_snapshot()
    previous_network = network_totals()
    history: deque[dict[str, Any]] = deque(maxlen=MAX_HISTORY)

    while True:
        time.sleep(SAMPLE_INTERVAL)

        timestamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        current_total, current_cores = cpu_snapshot()
        current_network = network_totals()

        cpu_total_percent = cpu_percent(previous_total, current_total)
        per_core = []
        for index, current_core in enumerate(current_cores):
            prev_core = previous_cores[index] if index < len(previous_cores) else current_core
            per_core.append({"core": index, "usage_percent": cpu_percent(prev_core, current_core)})

        net_payload: dict[str, Any] = {}
        for iface, totals in current_network.items():
            prev = previous_network.get(iface, totals)
            rx_rate = max(0.0, (totals["rx_bytes"] - prev["rx_bytes"]) / SAMPLE_INTERVAL)
            tx_rate = max(0.0, (totals["tx_bytes"] - prev["tx_bytes"]) / SAMPLE_INTERVAL)
            net_payload[iface] = {
                "totals": totals,
                "rates": {
                    "rx_bytes_per_sec": round(rx_rate, 2),
                    "tx_bytes_per_sec": round(tx_rate, 2),
                },
            }

        payload: dict[str, Any] = {
            "timestamp": timestamp,
            "cpu": {
                "total_percent": cpu_total_percent,
                "core_count": len(current_cores),
                "per_core": per_core,
                "load_average": load_average(),
            },
            "memory": meminfo(),
            "temperature_c": temperature_c(),
            "network": net_payload,
            "filesystem": filesystem_usage(),
        }

        history.append(
            {
                "timestamp": timestamp,
                "cpu_total_percent": cpu_total_percent,
                "memory_used_percent": payload["memory"]["memory_bytes"]["used_percent"],
                "temperature_c": payload["temperature_c"],
                "network": {
                    iface: values["rates"] for iface, values in net_payload.items()
                },
            }
        )

        write_json(CURRENT_FILE, payload)
        write_json(HISTORY_FILE, {"samples": list(history)})

        previous_total = current_total
        previous_cores = current_cores
        previous_network = current_network


if __name__ == "__main__":
    main()
