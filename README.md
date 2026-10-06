# arty-scope-hdl

VHDL design for a digital oscilloscope built on the Digilent Arty A7 100T (Artix-7) with a custom analog expansion board.

## Hardware

- **FPGA board:** Digilent Arty A7 100T (Artix-7 - xc7a100tcsg324-1)
- **ADC:** AD9288-100 (dual 8-bit, 100 MS/s)
- **PGA:** AD8370 (variable gain amplifier)
- **DAC:** MCP4822 (dual 12-bit, SPI)

## Related repositories

- PCB: [arty-scope-expansion-board](https://github.com/Filip-Kubecki/arty-scope-expansion-board)

## Repository structure

```
rtl/           VHDL sources
tb/            testbenches
constraints/   XDC files
ip/            Vivado IP definitions (.xci only)
scripts/       Tcl scripts (project creation)
docs/          notes
build/         generated Vivado project (git-ignored)
```

## Getting started

```bash
git clone https://github.com/Filip-Kubecki/arty-scope-hdl.git
cd arty-scope-hdl
vivado -mode batch -source scripts/create_project.tcl
```

Then open `build/arty_scope.xpr` in Vivado. The Vivado project is generated from the script and is not stored in git.

## Status

Work in progress.
