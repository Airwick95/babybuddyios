#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/babybuddy-forecast-api.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/modules"
swiftc -parse-as-library -module-cache-path "$scratch/modules" \
    "$repo/Sources/Shared/Forecast/ActivityForecast.swift" \
    "$repo/Sources/Shared/Forecast/ForecastAPIConfiguration.swift" \
    "$repo/Sources/Features/ForecastAPI/ForecastAPIClient.swift" \
    "$repo/scripts/ForecastAPIChecks.swift" -o "$scratch/checks"
"$scratch/checks"
