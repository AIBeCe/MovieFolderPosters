#!/bin/bash
set -euo pipefail

movie_repository=$(cd "$(dirname "$0")/.." && pwd)
movie_mode=${1:-run}
if [[ $# -gt 0 ]]; then shift; fi
movie_derived_data=${MOVIE_POSTERS_DERIVED_DATA:-${TMPDIR:-/tmp}/MovieFolderPosters-Development}
movie_app="$movie_derived_data/Build/Products/Debug/MovieFolderPosters.app"
movie_log="$movie_derived_data/build.log"
rtk proxy mkdir -p "$movie_derived_data"
rtk proxy pkill -x MovieFolderPosters >/dev/null 2>&1 || true
if ! rtk proxy xcodebuild -project "$movie_repository/MovieFolderPosters/MovieFolderPosters.xcodeproj" \
    -scheme MovieFolderPosters -configuration Debug -derivedDataPath "$movie_derived_data" \
    -allowProvisioningUpdates build >"$movie_log" 2>&1; then
    rtk proxy tail -n 50 "$movie_log"
    exit 1
fi
rtk proxy pkill -x MovieFolderPostersFinder >/dev/null 2>&1 || true
rtk proxy pluginkit -a "$movie_app/Contents/PlugIns/MovieFolderPostersFinder.appex"
rtk proxy open -n "$movie_app" --args "$@"
case "$movie_mode" in
    run) ;;
    --debug) rtk proxy lldb -n MovieFolderPosters ;;
    --logs) rtk proxy log stream --info --style compact --predicate 'process == "MovieFolderPosters"' ;;
    --telemetry)
        rtk proxy log stream --info --style compact \
            --predicate 'subsystem == "dag.fikios.MovieFolderPosters"' ;;
    --verify)
        for movie_attempt in {1..10}; do
            if rtk proxy pgrep -x MovieFolderPosters >/dev/null; then exit 0; fi
            rtk proxy sleep 0.2
        done
        exit 1 ;;
    *) printf 'Usage: %s [run|--debug|--logs|--telemetry|--verify] [app arguments]\n' "$0" >&2; exit 2 ;;
esac
