#!/bin/sh
set -eu

wait_for() {
    remaining=270
    until [ -f "$ZELDA_TEST_MARKER.$1" ]; do
        remaining=$((remaining - 1))
        [ "$remaining" -gt 0 ] || exit 11
        /bin/sleep 0.04
    done
}

case "$1:$2" in
    before:fast)
        printf '%s\n' '{"status":"ready"}' ;;
    before:slow)
        # Report early to verify the UI waits for actual helper exit as well as stdout.
        printf '%s\n' '{"status":"ready"}'
        exec 1>&-
        wait_for shown
        printf '%s\n' 'helper finished' > "$ZELDA_TEST_MARKER"
        ;;
    before:malformed)
        wait_for shown
        printf '%s\n' 'not JSON'
        exit 3
        ;;
    before:offline)
        wait_for shown
        printf '%s\n' '{"status":"unavailable"}'
        exit 1
        ;;
    before:cancel|before:choose|before:choose-conflict)
        wait_for shown
        printf '%s\n' '{"status":"conflict","choices":[{"id":"fixture-mac","created":"2026-11-10T12:00:00Z","device":"Mac"}]}' ;;
    resolve:choose)
        [ "${3:-}" = fixture-mac ]
        printf '%s\n' 'fixture-mac' > "$ZELDA_TEST_MARKER"
        printf '%s\n' '{"status":"resolved"}' ;;
    resolve:choose-conflict)
        [ "${3:-}" = fixture-mac ]
        printf '%s\n' '{"status":"conflict"}' ;;
    before:nonzero-json)
        printf '%s\n' '{"status":"ready"}'
        exit 9 ;;
    before:signalled-json)
        printf '%s\n' '{"status":"ready"}'
        kill -TERM "$$" ;;
    before:missing-status)
        printf '%s\n' '{}' ;;
    before:empty-status)
        printf '%s\n' '{"status":""}' ;;
    before:unknown-status)
        printf '%s\n' '{"status":"unknown"}' ;;
    before:wrong-status)
        printf '%s\n' '{"status":"published"}' ;;
    before:valid-empty)
        printf '%s\n' '{"status":"empty"}' ;;
    before:valid-imported)
        printf '%s\n' '{"status":"imported"}' ;;
    before:bad-choice)
        printf '%s\n' '{"status":"conflict","choices":[{"id":7,"created":"2026-11-10T12:00:00Z","device":"Mac"}]}' ;;
    before:quit|before:quit-timeout)
        printf '%s\n' "$$" > "$ZELDA_TEST_MARKER.pid"
        printf '%s\n' '{"status":"ready"}'
        exec 1>&-
        wait_for quit-shown
        if [ "$2" = quit-timeout ]; then wait_for reply-no; fi
        /bin/sleep 0.25
        printf '%s\n' 'writer completed' > "$ZELDA_TEST_MARKER"
        ;;
    before:lifecycle|game:lifecycle|after:lifecycle)
        printf '%s\n' "$$" > "$ZELDA_TEST_MARKER.entered-$1"
        wait_for "allow-$1"
        case "$1" in
            before) printf '%s\n' '{"status":"ready"}' ;;
            after) printf '%s\n' '{"status":"published"}' ;;
        esac
        ;;
    after:bad-post)
        printf '%s\n' '{"status":"ready"}' ;;
    after:post)
        /bin/sleep 0.6
        printf '%s\n' '{"status":"published"}' ;;
    *)
        printf '%s\n' 'unexpected fixture action' >&2
        exit 10 ;;
esac
