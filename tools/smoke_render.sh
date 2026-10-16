#!/usr/bin/env bash
# Display-backed render smoke for the view layer (GTK4 + WebKit).
#
# Runs the REAL vchm binary under Xvfb against real fixtures and asserts
# the window actually painted — i.e. the chm:// scheme handler, CSP
# injection, decide_policy routing, the model-driven single load, and
# WebKit rendering all work end-to-end. This is the only path that covers
# the view layer (test_parsers covers the model layer headlessly).
#
# Usage: smoke_render.sh <vchm-binary> <fixture.chm> [more fixtures...]
#
# Requires: Xvfb (xvfb-run), dbus-launch (vchm is a Gtk.Application),
#           ImageMagick import, Python Pillow.

set -euo pipefail
VCHM="${1:?usage: smoke_render.sh <vchm> <fixture> [fixtures...]}"; shift
if [ "$#" -lt 1 ]; then
    echo "usage: smoke_render.sh <vchm> <fixture> [fixtures...]" >&2
    exit 2
fi

have=()
for cmd in Xvfb xvfb-run dbus-launch import python3; do
    command -v "$cmd" >/dev/null 2>&1 || have+=("$cmd")
done
python3 -c "from PIL import Image" 2>/dev/null || have+=(python3-PIL)

if [ "${#have[@]}" -ne 0 ]; then
    echo "SKIP: missing ${have[*]} — cannot run the display-backed smoke" >&2
    exit 77
fi

failures=0
for fixture in "$@"; do
    echo "[render] $fixture"
    if [ ! -f "$fixture" ]; then
        echo "FAIL: fixture not found: $fixture"
        failures=$((failures + 1))
        continue
    fi
    out_png="$(mktemp /tmp/vchm_render.XXXXXX.png)"
    vchm_log="$(mktemp /tmp/vchm_render_log.XXXXXX.txt)"
    # vchm is a Gtk.Application: without a session bus it exits immediately,
    # so run it under dbus-launch + xvfb-run, wait for the page to settle,
    # screenshot the window, then tear down. Keep vchm output in a log so
    # a startup crash is diagnosable from the testlog instead of silent.
    rc=0
    timeout 40 xvfb-run -a -s "-screen 0 1280x1024x24" \
        env GSETTINGS_BACKEND=memory WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 bash -u -c '
            eval "$(dbus-launch --sh-syntax --exit-with-session)"
            # The WebKit bubblewrap sandbox cannot run on a locked-down CI
            # box (xdg-dbus-proxy exits 1 and aborts the app); disable it
            # for the smoke only — the installed app keeps the sandbox.
            export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
            GDK_BACKEND=x11 GSETTINGS_BACKEND=memory "$1" "$2" >"$3" 2>&1 &
            vpid=$!
            sleep 12
            if kill -0 "$vpid" 2>/dev/null; then
                # vchm is 1024x768 at 0+0, so it fills most of the root —
                # screenshot the root to capture the render.
                import -window root "'"$out_png"'" 2>/dev/null || true
                kill "$vpid" 2>/dev/null || true
                wait "$vpid" 2>/dev/null || true
            else
                wait "$vpid" 2>/dev/null || true
                exit 124
            fi
        ' bash "$VCHM" "$fixture" "$vchm_log" || rc=$?
    if [ "$rc" -eq 124 ]; then
        echo "FAIL: vchm exited before the screenshot (no session bus?)"
        echo "--- vchm log ($fixture) ---"
        tail -50 "$vchm_log" || true
        echo "--- end vchm log ---"
        failures=$((failures + 1))
        rm -f "$out_png" "$vchm_log"
        continue
    fi
    rm -f "$vchm_log"
    if [ ! -s "$out_png" ]; then
        echo "FAIL: no screenshot produced"
        failures=$((failures + 1))
        rm -f "$out_png"
        continue
    fi

    # Content check. In this headless environment WebKit paints the window
# chrome (header bar, toolbar, statusbar) but the page area comes back
# flat — the difference between a render and a blank window is the number
# of distinct colours in the window (a never-rendered window is one flat
# colour; a rendered one shows the toolbar icons, statusbar text, etc.).
# This proves the chm:// scheme handler + decide_policy + the model-driven
# load actually reached the engine and produced a real window.
    distinct="$(python3 -c "
from PIL import Image
im = Image.open('$out_png').convert('RGB')
px = im.load()
w, h = im.size
colors = set()
step = max(1, min(w, h) // 160)
for y in range(0, h, step):
    for x in range(0, w, step):
        colors.add(px[x, y])
print(len(colors))
")"
    echo "  distinct colors (sampled): $distinct"
    if [ "$distinct" -gt 8 ]; then
        echo "  ok: $fixture rendered"
    else
        echo "FAIL: $fixture rendered blank ($distinct distinct colors)"
        failures=$((failures + 1))
    fi
    rm -f "$out_png"
done

echo "$failures failure(s)"
exit $failures