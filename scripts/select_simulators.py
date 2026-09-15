"""Select one iPhone and iPad from the newest available iOS simulator runtime."""
import json
import re
import sys


def select_devices(data):
    runtimes = []
    for runtime, devices in data["devices"].items():
        match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if match and int(match[1]) >= 17:
            runtimes.append((tuple(int(v or 0) for v in match.groups()), devices))
    for _, devices in sorted(runtimes, key=lambda item: item[0], reverse=True):
        chosen = []
        for family in ("iPhone", "iPad"):
            device = next((d for d in devices if d.get("isAvailable") and family in d["name"]), None)
            if device:
                chosen.append((family, device["udid"]))
        if len(chosen) == 2:
            return chosen
    raise SystemExit("Install an iOS 17+ simulator runtime with both iPhone and iPad devices.")


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as source:
        for family, udid in select_devices(json.load(source)):
            print(family, udid)
