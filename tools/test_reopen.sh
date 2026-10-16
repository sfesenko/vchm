#!/bin/bash
# Integration test for open-close-reopen blank (Fort book).
# Runs vchm under Xvfb, opens a CHM, navigates, closes, reopens, and
# verifies the viewer shows content (not blank white) after the cycle.
# Needs xvfb-run, dbus-launch, import (ImageMagick) and Pillow at runtime;
# missing tools cause the test to SKIP, not FAIL.

set -e

if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "SKIP: xvfb-run not found"
  exit 0
fi
if ! command -v dbus-launch >/dev/null 2>&1; then
  echo "SKIP: dbus-launch not found"
  exit 0
fi
if ! command -v import >/dev/null 2>&1; then
  echo "SKIP: import (ImageMagick) not found"
  exit 0
fi
if ! python3 -c "import PIL" 2>/dev/null; then
  echo "SKIP: Pillow not found"
  exit 0
fi

VCHM="$1"
if [ -z "$VCHM" ] || [ ! -x "$VCHM" ]; then
  echo "SKIP: vchm binary not found"
  exit 0
fi

# Use the first fixture as the test book if no explicit book given.
# The caller (meson) passes fixtures as $2.. ; we pick $2.
BOOK="$2"
if [ -z "$BOOK" ]; then
  BOOK="$(dirname "$VCHM")/tests/basic.chm"
fi
if [ ! -f "$BOOK" ]; then
  echo "SKIP: test book not found: $BOOK"
  exit 0
fi

export GDK_BACKEND=x11
export GSETTINGS_BACKEND=memory
# The WebKit bubblewrap sandbox cannot run on a locked-down CI box
# (xdg-dbus-proxy exits 1 and aborts the app); disable it for the
# test only — the installed app keeps the sandbox.
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export GSETTINGS_SCHEMA_DIR="$(dirname "$VCHM")/data"
if [ ! -d "$GSETTINGS_SCHEMA_DIR" ]; then
  GSETTINGS_SCHEMA_DIR="$(dirname "$(dirname "$VCHM")")/builddir/data"
fi
export GSETTINGS_SCHEMA_DIR

TMPDIR=$(mktemp -d)
LOG="$TMPDIR/vchm.log"
PNG2="$TMPDIR/after_reopen.png"

# main.vala owns the cycle: when VCHM_TEST_REOPEN_CYCLE=1 it dispatches
# TestReopenMessage at t+3s and re-dispatches OpenFileMessage at t+5s
# (main.vala:94-103), so the close/reopen cycle is driven entirely inside
# the Elmish loop. We only need to screenshot after both have fired and
# assert the viewer repainted.

timeout 20 xvfb-run -a -s "-screen 0 1280x1024x24" bash -c '
  set -e
  # shellcheck disable=SC1091
  eval "$(dbus-launch --sh-syntax --exit-with-session)"
  export GDK_BACKEND=x11
  export GSETTINGS_BACKEND=memory
  export GSETTINGS_SCHEMA_DIR="'"$GSETTINGS_SCHEMA_DIR"'"
  export VCHM_TEST_REOPEN_CYCLE="1"
  export VCHM_TEST_REOPEN_BOOK="'"$BOOK"'"
  timeout 15 stdbuf -oL -eL "'"$VCHM"'" "'"$BOOK"'" > "'"$LOG"'" 2>&1 &
  VPID=$!
  # Wait for first open and then do close/reopen via the hook
  sleep 8
  # Take screenshot after the cycle (hook should have done close/reopen by now)
  import -window root "'"$PNG2"'" 2>&1 || true
  # Also take one earlier if possible
  sleep 1
  kill $VPID 2>/dev/null || true
  wait $VPID 2>/dev/null || true
' 2>&1 | head -100

if [ ! -f "$PNG2" ]; then
  echo "FAIL: screenshot not created"
  cat "$LOG" 2>/dev/null | tail -50 || true
  exit 1
fi

# Analyze screenshot
python3 - << PY
import sys
from PIL import Image
try:
    im = Image.open("$PNG2").convert("RGB")
except Exception as e:
    print(f"FAIL: cannot open screenshot: {e}")
    sys.exit(1)

# Viewer area: sidebar ~300px, header ~40px
# Crop to viewer as in smoke_render.sh
try:
    crop = im.crop((320, 60, 1280, 950))
except:
    crop = im

white = sum(1 for p in crop.getdata() if p == (255,255,255))
total = crop.width * crop.height
ratio = white / total if total else 1
print(f"screenshot {im.size}, crop {crop.size}, white {white}/{total} ({ratio:.2%})")
# Also count distinct colours
distinct = len(set(crop.getdata()))
print(f"distinct colours in crop: {distinct}")

# The viewer should have content, not be mostly white.
# A blank white page is >90% white, a rendered page has <85% white
# (due to text, images, etc.) and many distinct colours.
if ratio > 0.90:
    print("FAIL: viewer appears blank (mostly white) after reopen")
    sys.exit(1)
if distinct < 10:
    print("FAIL: viewer has too few colours (likely blank)")
    sys.exit(1)

print("PASS: viewer has content after reopen")
PY
status=$?
cat "$LOG" 2>/dev/null | tail -30 || true
rm -rf "$TMPDIR"
exit $status
