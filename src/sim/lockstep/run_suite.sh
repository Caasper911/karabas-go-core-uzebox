#!/bin/bash
# Lockstep test of the RTL against Uzem on the game set built by src/sim/build_uze.sh (4 in parallel).
# Usage: src/sim/lockstep/run_suite.sh [frames] [game ...]   Logs and the last frame (PNG) in src/sim/build/suite.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
N="${1:-300}"; shift
G="$ROOT/src/sim/build/uze/demos"
GAMES="${*:-unittest Megatris SpriteDemo DonkeyKong Mode9Demo Mode5Demo Mode13ExtendedDemo SpaceInvaders PacMan ControllerTester MusicDemo arkanoid}"
OUT="$ROOT/src/sim/build/suite"; mkdir -p "$OUT"
"$HERE/run_lockstep.sh" "$G/unittest/default/unittest.hex" -n 1 > /dev/null 2>&1   # build
EXE="$ROOT/src/sim/build/lockstep/obj/tb_lockstep.exe"
export PATH="/c/msys64/ucrt64/bin:$PATH"
run() {
	local g="$1" f
	if [ "$g" = arkanoid ]; then f="$ROOT/upstream/uzebox/tools/packrom/Test/arkanoid.uze"; else f="$G/$g/default/$g.hex"; fi
	( cd "$OUT" && "$EXE" "$f" -n "$N" -p "$OUT/$g" -e "$N" > "$OUT/$g.log" 2>&1 )
	echo "$g: $(grep -v joystick "$OUT/$g.log" | head -1)"
}
i=0
for g in $GAMES; do run "$g" & i=$((i + 1)); [ $((i % 4)) -eq 0 ] && wait; done
wait
