# wiz-icestick-uart

A UART for the Lattice iCEstick, written in [Wiz](https://github.com/badly-drawn-wizards/wiz)'s
hardware description library, built with grail (Wiz's build tool), simulated three
ways, partly proved, and tested on the board over its serial port.

It exists to use Wiz, its HDL library and grail the way a stranger would, and to write
down what that was like: see [FINDINGS.md](FINDINGS.md).

```
src/Icestick/*.wiz ── grail build ──▶ .grail/bin/icestick      (the flow driver, in Wiz)
                                          │ gen      Verilog, pin constraints, test benches, traces
                                          │ sim      Icarus Verilog replays the traces
                                          │ bit      yosys ▶ nextpnr-ice40 ▶ icepack, icetime
                                          │ postsim  the same traces on the synthesised netlists
                                          │ flash    iceprog
                                          ▼ test     random lines over the serial port, CRCs checked
```

## The board

Lattice iCEstick: an iCE40HX1K in a TQ144 package, a 12 MHz oscillator, five LEDs and
an FT2232H whose second channel is a serial port.

| signal | FPGA pin | port |
|---|---|---|
| 12 MHz clock | 21 | `clk` |
| UART RX (host → FPGA) | 9 | `uart_rx` |
| UART TX (FPGA → host) | 8 | `uart_tx` |
| LED1 … LED4 (red), LED5 (green) | 99, 98, 97, 96, 95 | `leds[0]` … `leds[4]` |

The ports come from the bundles `Pins` and `Board` (`src/Icestick/Gates.wiz`), and
`build/icestick.pcf` is generated from them (`Pcf.emit`, checked by `Pcf.check`).

(Pin numbers from icestorm's `examples/icestick/icestick.pcf`. The clock and the two
UART pins are confirmed by the board answering.)

The serial port is 115200 baud, 8 data bits, no parity, one stop bit. The board
divides its clock by 104: 115384.6 baud, 0.16 % fast.

## The designs

All four are `Circuit Pins.code Board.code` values in `src/Icestick/Designs.wiz` (one
Mealy machine each, state, input and output as bundles, i.e. structures of signals with
`deriving Bundle`), built from the same parts in `src/Icestick/Uart.wiz` (baud divider,
transmitter, receiver, input synchroniser). Every register is named after its field
(`tx_cnt`, `rx_ph`, `crc`, …) in the Verilog.

| design | what it does | logic cells (of 1280) | Fmax (nextpnr) |
|---|---|---|---|
| `blinky` | a 24-bit counter on the LEDs; LED5 blinks at 0.72 Hz | 27 | 209 MHz |
| `hello` | sends `Hello from Wiz!\r\n`, waits 0.35 s, again | 105 | 140 MHz |
| `echo` | sends back every byte it receives | 79 | 216 MHz |
| `proto` | a CRC service: see below | 125 | 191 MHz |

The clock is 12 MHz, so timing is not a concern.

**A toy CPU.** `src/Icestick/Cpu.wiz` is a minimal 8-bit accumulator processor (fourteen
instructions, eight bytes of memory, the LEDs and the UART), specified as a pure step
function and proved equal to its circuit cycle by cycle; `src/Icestick/Asm.wiz` is its
assembler. Three more designs run its example programs: `cpu_count` (counts on the
LEDs), `cpu_echo` (sends back each byte plus one) and `cpu_hi` (sends `hi\r\n`). See
[docs/cpu.md](docs/cpu.md).

**The protocol of `proto`.** The host sends a line: any bytes except 0x0A, then 0x0A.
The board answers with the CRC-8 of the line's bytes (polynomial 0x07, initial value 0:
CRC-8/SMBUS) as two upper-case hexadecimal digits and 0x0A. `123456789` gives `F4`;
the empty line gives `00`. LED1 … LED4 count the lines, LED5 is on. The host must wait
for the answer before it ends the next line.

## Building

You need Nix with flakes. `nix develop` gives a shell with `wiz`, `grail` (from the
Wiz flake, pinned in `flake.lock`), yosys, nextpnr-ice40, icestorm, Icarus Verilog,
`stty` and socat.

```sh
nix develop
grail build                 # check the designs and the proofs, compile the driver
grail test                  # the simulation tests (tests/*.wiz)
.grail/bin/icestick all     # gen, sim, bit, postsim: everything short of the board
```

The first `grail build` takes about five minutes on four cores, nearly all of it the kernel checking
the loopback proofs (`grail build icestick` builds the driver alone in seconds); after
that grail's cache answers. Without the Cachix cache of the Wiz project as a trusted
substituter, Nix also builds wiz from source the first time (a few minutes).

With tower, Wiz's toolchain manager, instead of the flake's `wiz`: `wiz-toolchain`
names the commit this repository is developed against (master b6ad475, the commit
`flake.lock` pins too; it needs Wiz PRs #91, #108 and #118 for the HDL library's named
ports, bundles, emitters and the step functions without `BStep`). tower installs it
from the commit's release snapshot, and its `wiz` and `grail` shims pick it up in this
directory (`tower show`; see the Wiz documentation, stage 26). The release ships its own
C compiler and GMP, so no `grail.local.wiz` is needed. You then need yosys,
nextpnr-ice40, icestorm and iverilog from somewhere else (the devShell has them).

The output is in `build/`: `NAME.v` (the Verilog), `NAME.bin` (the bitstream),
`icestick.pcf`, reports and logs.

## On the board

`iceprog` needs write access to the board's USB device (vendor 0403, product 6010).
On most systems that takes a udev rule, for example

```
SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="6010", MODE="0660", GROUP="plugdev", TAG+="uaccess"
```

`iceprog -t` reads the flash chip's identity without writing anything: if that works,
flashing will. **Flashing replaces whatever bitstream the board holds.**

```sh
.grail/bin/icestick flash proto
.grail/bin/icestick test /dev/ttyUSB1          # 200 random lines and the empty one
.grail/bin/icestick test /dev/ttyUSB1 3000     # more
```

The UART is the board's second serial device (`/dev/ttyUSB1` if the board is the only
adapter; `/dev/serial/by-id/usb-Lattice_Lattice_FTUSB_Interface_Cable-if01-port0`
always). After `iceprog` has run, the first one (`ttyUSB0`, the programming channel)
is gone until the board is plugged in again; that is normal.

The test prints `PASS: 201 lines, every CRC as expected` and exits 0, or says which
line got which answer (or none within 2 s) and exits 1.

The other designs, by hand:

```sh
P=/dev/ttyUSB1
stty -F $P 115200 raw -echo cs8 -cstopb -parenb clocal min 0 time 10
.grail/bin/icestick flash hello && timeout 2 cat $P        # Hello from Wiz!
.grail/bin/icestick flash echo
head -c 4096 /dev/urandom > r.bin; (timeout 4 cat $P > e.bin &); sleep 0.5; cat r.bin > $P; sleep 4; cmp r.bin e.bin
```

### Results on a real iCEstick (2026-11-11)

(With the designs as of wiz fe4e9c4, on `master`. The `wiz-nightly` branch, ported to the
named-port API, has been simulated and synthesised but not run on the board.)

| design | check | result |
|---|---|---|
| `blinky` | flashed and verified by iceprog; the UART stays silent | 0 bytes in 2 s (the LEDs were not looked at) |
| `hello` | `timeout 2 cat` | `Hello from Wiz!\r\n`, six times in 2 s |
| `echo` | 4096 random bytes (all values), sent back to back | came back identical |
| `proto` | `icestick test`, 200 random lines of up to 59 bytes | `PASS: 201 lines, every CRC as expected` (5 s) |
| `proto` | `icestick test PORT 3000` | `PASS: 3001 lines, every CRC as expected` (50 s) |
| `proto` | `123456789` by hand | `F4` |

### Without a board

`icestick fake PORT` is the board on a pseudo-terminal: each line it reads goes through
the `proto` circuit, simulated cycle by cycle, as a waveform, and what the circuit's TX
line carries is written back. The host test cannot tell the difference, except that it
is slow (give it time: 100 tenths of a second per answer):

```sh
socat pty,raw,echo=0,link=$PWD/build/ptyA pty,raw,echo=0,link=$PWD/build/ptyB &
.grail/bin/icestick fake build/ptyA &
.grail/bin/icestick test build/ptyB 20 100
```

## How it is tested

One description of each design; four things run it, and they must agree.

1. **Values** (`Circuit` at the representation `HwTy.El`): `Sim.run` steps the circuit
   on bit vectors. The input is the RX pin cycle by cycle, made from the bytes the host
   sends with the host's bit period (625/6 cycles: 115200 baud at 12 MHz, not the
   board's 104), and the bytes on the TX line are decoded by a software receiver and
   compared with what the design must send (for `proto`, the CRC specification on
   numbers, `Crc.reply`).
2. **The netlist** (`Circuit` at the representation `Wire`): the netlist interpreter of
   the HDL library replays the whole trace and must give the same outputs.
3. **The Verilog**: Icarus Verilog replays the whole trace on the emitted module
   (`icestick sim`) and on yosys's synthesised netlist with the iCE40 cell models
   (`icestick postsim`): the output must match the values of (1) in every cycle
   (206022 cycles for `proto`).
4. **The board**: the same protocol, the same specification, over the serial port
   (`icestick test`).

`grail test` adds: the hardware CRC step against the specification for all 65536 pairs
of CRC and byte; the loopback for every byte at the board's divider; `proto` with a
host that is 2 % and 4 % fast or slow (right answers) and 8 % (wrong ones, as it must
be); `hello` twice with a short pause.

## What is proved

In `src/Icestick/Proofs.wiz` and `src/Icestick/Proofs/`, checked by the Wiz kernel on
`grail build`, about the same step functions that are synthesised:

* **The baud divider has period exactly 104, for ever.** `Baud.period`: after any
  number `m` of periods from the initial state, the next 104 cycles tick exactly once,
  in the last cycle. (A lemma about iteration, by induction, and two facts the kernel
  gets by running `baudStep` for 104 cycles.)
* **Loopback at the board's divider.** A transmitter wired to a receiver through the
  synchroniser, 104 cycles per bit: for the bytes 0x00, 0xFF, 0x55 and 0xAA, exactly
  one byte arrives within 1100 cycles and it is the byte sent
  (`Loop.board_00`, …; `Proofs/Board.wiz`).
* **Loopback for every byte, at 8 cycles per bit.** The same statement for all 256
  bytes, in sixteen ranges (`Loop.range_00` … `Loop.range_f0`), each of which gives
  its members by `Loop.inRange`.

What is *not* proved: every byte at 104 cycles per bit (the kernel would need about
2.5 hours; the compiled test covers it), one statement for all 256 bytes instead of
sixteen (FINDINGS.md, G11), anything about `proto` as a whole, anything about
arbitrary input waveforms, and that the Verilog or the bitstream mean what the circuit
means (that is what the simulations and the board are for).

## Layout

```
flake.nix, flake.lock    the toolchain and the FPGA tools
wiz-toolchain            the Wiz commit, for tower
grail.wiz                the package: library, driver, tests
src/Icestick/Gates.wiz   small vocabulary over the HDL library
src/Icestick/Uart.wiz    baud divider, transmitter, receiver, synchroniser
src/Icestick/Crc.wiz     CRC-8 as hardware and as a specification
src/Icestick/Designs.wiz blinky, hello, echo, proto; the loopback circuit
src/Icestick/Cpu.wiz     the toy CPU: architecture and circuit (docs/cpu.md)
src/Icestick/Asm.wiz     its assembler and example programs
src/Icestick/Wave.wiz    waveforms, a software receiver, the simulator loop, test data
src/Icestick/Board.wiz   pins, the list of designs, scenarios
src/Icestick/Proofs*     the proofs
app/icestick.wiz         the flow driver and the host-side test
tests/                   simulation tests for `grail test`
```

## Versions

wiz and grail `b6ad475` (2026-11-11), yosys 0.70, nextpnr 0.11.1, icestorm
2025-06-03, Icarus Verilog 13.0, from nixpkgs `02c087f` (the Wiz flake's pin).

## Licence

This project is free software: you can redistribute it and/or modify it under the terms of
the GNU General Public License as published by the Free Software Foundation, either version
3 of the License, or (at your option) any later version (SPDX: `GPL-3.0-or-later`), the
same licence as Wiz. It is distributed WITHOUT ANY WARRANTY; see [LICENSE](LICENSE).
