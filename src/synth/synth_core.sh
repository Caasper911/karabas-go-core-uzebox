#!/bin/bash
# XST + map + par + trce of atmega644 alone (no pins placed): LUTs, slices, BRAM, timing at 57.27 MHz.
# Usage: src/synth/synth_core.sh   (ISE 14.7 at C:\Xilinx\14.7\ISE_DS, run from Git Bash)
set -e
cd "$(dirname "$0")"
X=/c/Xilinx/14.7/ISE_DS
mkdir -p build/xst/tmp build/xst/projnav.tmp && cd build
cp ../avr.prj ../avr.xst ../avr.ucf .
sed -i 's|\.\./rtl|../../rtl|' avr.prj
export TEMP="$(cygpath -m "$PWD")/xst/tmp" TMP="$(cygpath -m "$PWD")/xst/tmp"
export XILINXD_LICENSE_FILE="$(cygpath -m "$X")/.xinstall/xilinx_ise.lic" XILINX="$X/ISE"
export PATH="$X/ISE/bin/nt64:$X/ISE/lib/nt64:$X/common/bin/nt64:$X/common/lib/nt64:$PATH"
P=xc6slx25-2-ftg256
xst -intstyle ise -ifn avr.xst -ofn atmega644.syr > /dev/null
ngdbuild -intstyle ise -dd _ngo -uc avr.ucf -p $P atmega644.ngc atmega644.ngd > /dev/null
map -intstyle ise -p $P -w -ol high -t 2 -o atmega644_map.ncd atmega644.ngd atmega644.pcf > /dev/null
par -w -intstyle ise -ol high atmega644_map.ncd atmega644.ncd atmega644.pcf > /dev/null
trce -intstyle ise -v 3 -s 2 -n 3 -fastpaths atmega644.ncd -o atmega644.twr atmega644.pcf > /dev/null
grep -E "Number of Slice LUTs|Number of occupied Slices|Number of Slice Registers|RAMB16BWER|RAMB8BWER|DSP48A1" atmega644_map.mrp | head
grep -E "Minimum period|constraints? (were|was) met|Timing errors" atmega644.twr | head -4
