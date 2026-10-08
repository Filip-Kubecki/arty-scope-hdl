<!-- markdownlint-disable MD013 MD060 -->

# Two-Channel Oscilloscope for Arty A7

VHDL design for a digital oscilloscope built on the Digilent Arty A7 100T (Artix-7) with a custom analog expansion board.

## Hardware

- **FPGA board:** Digilent Arty A7 100T (Artix-7 - xc7a100tcsg324-1)
- **ADC:** AD9288-100 (dual 8-bit, 100 MS/s)
- **PGA:** AD8370 (variable gain amplifier)
- **DAC:** MCP4822 (DC offset)

## Related repositories

- PCB: [arty-scope-expansion-board](https://github.com/Filip-Kubecki/arty-scope-expansion-board)

## Repository structure

```
rtl/           VHDL sources
tb/            testbenches
constraints/   XDC files
ip/            Vivado IP definitions
scripts/       Tcl scripts (project creation)
docs/          notes and documentation
build/         generated Vivado project (git-ignored)
```

## Getting started

Clone the repository first:

```bash
git clone https://github.com/Filip-Kubecki/arty-scope-hdl.git
cd arty-scope-hdl
```

The Vivado project is generated from `scripts/create_project.tcl` and is not stored in git. Create it using one of the two options below.

### Option 1: from the terminal

With Vivado available in your `PATH` (e.g. `source <Vivado install dir>/settings64.sh` on Linux), run from the repository root:

```bash
vivado -mode batch -source scripts/create_project.tcl
vivado build/arty_scope.xpr &
```

### Option 2: from the Vivado GUI

1. Start Vivado.
2. Choose **Tools → Run Tcl Script...** and select `scripts/create_project.tcl` from the cloned repository.
3. Vivado creates the project in `build/` and opens it automatically.

Alternatively, type these two lines in the Tcl console at the bottom of the window:

```tcl
cd /path/to/arty-scope-hdl
source scripts/create_project.tcl
```

To open an already generated project later, use **File → Open Project...** and select `build/arty_scope.xpr`.

Then open `build/arty_scope.xpr` in Vivado. The Vivado project is generated from the script and is not stored in git.

## Status

Work in progress.
