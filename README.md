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

The first four are `Circuit Pins.code Board.code` values in `src/Icestick/Designs.wiz` (one
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
| `ir` | the IR blaster: see below (`src/Icestick/Blaster.wiz`) | 1222 | 41 MHz |

The clock is 12 MHz, so timing is not a concern.

**The protocol of `proto`.** The host sends a line: any bytes except 0x0A, then 0x0A.
The board answers with the CRC-8 of the line's bytes (polynomial 0x07, initial value 0:
CRC-8/SMBUS) as two upper-case hexadecimal digits and 0x0A. `123456789` gives `F4`;
the empty line gives `00`. LED1 … LED4 count the lines, LED5 is on. The host must wait
for the answer before it ends the next line.

## The IR blaster

The iCEstick has an IrDA transceiver, a Vishay TFDU4101, on the end opposite the USB
plug: TXD on pin 105, RXD on 106, SD (shutdown) on 107 (Lattice's iCEstick user guide,
EB82, table 2). It is meant for IrDA (short pulses up to 115.2 kbit/s), but its LED
follows TXD for pulses of 1.6 µs to 23 µs, so it can send consumer infrared: 38 kHz
bursts. The designs `ir` (and `ir_fast`, the same circuit with faster timing, for
simulation) in `src/Icestick/Blaster.wiz` are a command prompt on the serial port that
sends NEC frames, the protocol of LG televisions:

```
ir> on
sent 04 FB C4 3B (20DF23DC) +0, echo ok
ir> power
sent 04 FB 08 F7 (20DF10EF) +4, echo ok
ir> listen
listening
rx 04 FB 08 F7 (20DF10EF)
rx repeat
```

| command | sends |
|---|---|
| `on` | LG POWER ON: NEC address 0x04, command 0xC4 (discrete: switches on, never off) |
| `off` | LG POWER OFF: command 0xC5 (discrete) |
| `power` | LG POWER: command 0x08 (toggles; what the power key of an LG remote sends), followed by 4 repeat codes |
| `raw AA CC` | NEC address `AA`, command `CC` (hexadecimal) |
| `raw AAAA CC` | extended NEC: the two address bytes in the order sent, no complement |
| `listen` | print every frame the receiver decodes, until a key is pressed |
| `hold N` | from now on, follow every frame with N repeat codes (0 … 9); with 0, `power` still sends 4 |
| `help` or `?` | the list |

To try it: `.grail/bin/icestick flash ir`, then `screen /dev/ttyUSB1 115200` (leave with
Ctrl-A k y), point the end of the board opposite the USB plug at the TV and type `on`
or `power` and Enter. `.grail/bin/icestick irtest /dev/ttyUSB1` sends `on` and `power`
and checks both answers.

An answer gives the four bytes in the order sent (address, its complement, command,
its complement), the 32 bits with the first bit sent on top, and the number of repeat
codes after the frame (`+4`), which is how LIRC,
IRremote and most web pages write NEC codes (`0x20DF10EF` for LG's power key).
`echo ok` means the decoder saw that very frame come back: the TFDU4101 echoes what it
transmits on its RXD pin, so this shows that the frame left the FPGA as a frame and
that the LED was driven; it does not show that a TV saw it. Typed characters are
echoed, backspace and ^C work, CR or LF ends a line; bytes typed while the board
answers are dropped (an answer to `on` takes 0.1 s). LEDs: LED1 sending, LED2 a frame
coming in, LED3 listening, LED4 the last frame came back, LED5 (green) on.

**The codes.** LG TVs use NEC with address 0x04: POWER 0x08, and on many models the
discrete POWER ON 0xC4 and POWER OFF 0xC5 (IRDB, `codes/LG/TV/4,-1.csv`: `POWER,NEC1,4,-1,8`,
`POWER ON,NEC1,4,-1,196`, `POWER OFF,NEC1,4,-1,197`;
https://github.com/probonopd/irdb). Written as 32-bit codes those are 0x20DF10EF,
0x20DF23DC and 0x20DFA35C, as in LG code lists (for example
https://gist.github.com/francis2110/8f69843dd57ae07dce80, "P-ON 20DF23DC", "P-OFF
20DFA35C") and as an ESPHome receiver logs the power key of an LG remote
(https://community.home-assistant.io/t/esphome-problem-with-ir-remote-and-lg-tv/182519).
Older and some newer LG sets ignore the discrete codes; `power` works on all of them.
The NEC timing is that of the Linux kernel's decoder (drivers/media/rc/ir-nec-decoder.c:
a unit of 562.5 µs, a leader of 16 units on and 8 off, a one as 1 on and 3 off, a zero as
1 and 1, a final unit on; a repeat code is 16 on, 4 off, 1 on).

**The transmitter.** 12 MHz / 316 = 37975 Hz, on for 60 cycles (5 µs) of each 316:
a duty cycle of 19 %, not the third that remotes often use, because the TFDU4101's
absolute maximum ratings allow its pulsed LED current (about 300 mA, set inside the
part) only below 20 % duty (and pulses below 90 µs; its own protection turns the LED off
after 50 µs to 300 µs of TXD high). A unit is 6750 cycles exactly. A frame (LG: 121
units, 68 ms) is followed by a 40-unit gap, or by repeat codes (16 units on, 4 off, 1 on:
what a remote sends while a key is held), each starting 192 units (108 ms) after the
one before. On an LG TV that answered `on` and `off`, a single `power` frame did
nothing, and a frame with four repeat codes (0.54 s, a short press) toggled it: that is
what `power` sends; `hold N` gives every command N of them.

How well that works is for a TV to say. The LED emits at 870 nm to 910 nm, where TV
receivers (tuned to 940 nm) are less sensitive, but it is bright (radiant intensity 50
to 400 mW/sr, typically 150, at ±30°, about as much as a remote's LED); a 19 % duty
cycle puts about two thirds of the fundamental of a 33 % one into the 38 kHz band.
Expect it to work across a room when pointed at the TV; it is not tested on a TV here.

**The receiver** reports each rising edge of the light it sees as a 2 µs low pulse
on RXD, whatever the pulse's length. The decoder (`necRxStep` in `Ir.wiz`) turns pulses
seen within 50 µs into a mark, measures marks and spaces, and decodes NEC frames and
repeat codes; `listen` prints them. Whether a remote at 940 nm and 38 kHz gets through
the IrDA receiver's filters is for the board to show (see the results below).

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

### The IR blaster on the board (2026-11-11)

First version (1202 of 1280 logic cells, 44 MHz, no repeat codes), over `/dev/ttyUSB1`:

```
ir> help                on off power raw AA[AA] CC listen
ir> on                  sent 04 FB C4 3B (20DF23DC), echo ok
ir> power               sent 04 FB 08 F7 (20DF10EF), echo ok
ir> off                 sent 04 FB C5 3A (20DFA35C), echo ok
ir> raw 04FB 08         sent 04 FB 08 F7 (20DF10EF), echo ok
ir> raw 20 df           sent 20 DF DF 20 (04FBFB04), echo ok
ir> bogus               what? (help)
ir> onn<DEL>            (echoed as BS SP BS) sent 04 FB C4 3B (20DF23DC), echo ok
ir> listen              listening, key stops   (no remote at hand: nothing; a key: prompt)
```

`echo ok` each time: the TFDU4101's receiver saw the board's own light and the decoder
turned it back into the frame sent, so the LED was driven with NEC timing. Whether a TV
reacts was not observed (no TV in reach of the board), nor whether the IrDA receiver
sees a 940 nm remote (`listen` with an LG remote a few centimetres away will tell).

With an LG TV in front of the board (the user watching): `on` and `off` switched it on
and off; a single `power` frame did nothing. Hence the repeat codes. Second version
(1222 cells), 21:45:41: `power` → `sent 04 FB 08 F7 (20DF10EF) +4, echo ok`, and the
TV toggled. So this LG TV needs the power toggle held (a frame and repeat codes), while
the discrete POWER ON and POWER OFF codes work as a single frame.

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

For `ir` the TXD pin goes back to its RXD through a model of the transceiver (a 2 µs low
pulse at each rising edge of the light, `IrSim.run`), and the trace is replayed like the
others. `ir` (the board's timing) gets lines that send no frame; `ir_fast` (the same
circuit, 25 times faster IR timing, a 16-cycle UART bit) sends `on`, `power`, `off`, two
`raw` frames and listens to a simulated remote with its own carrier (a frame and a
repeat code): every answer, including `echo ok`, must be the specification's.

`grail test` adds: for `ir`, the frame words for all 65536 (address, command) pairs; the
encoder alone (at `ir_fast`'s timing: a frame at the board's takes 1.1 million cycles,
more than grail's 60 s per test allows), its TXD waveform cut into carrier pulses, marks
and frames, which must be NEC to the cycle (every pulse and every carrier period as
configured, every mark on the unit grid) and decoded back from its echo, for LG POWER,
ON and an extended frame. And: the hardware CRC step against the specification for all 65536 pairs
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

* **The IR frames** (`src/Icestick/Proofs/Ir.wiz`): for every command byte at LG's
  address the hardware's 32 bits (`necWordX`) are the specification's (`Nec.word`), and
  so are the reversed ones (`scan32`); the three LG codes as the hardware builds them
  are 0x20DF10EF, 0x20DF23DC and 0x20DFA35C; `necLen` gives each of the 68 segments of a
  frame its length, and along the LG frames that is the specification's list of
  marks and spaces; the carrier counter has period 316 with the LED on in its first 60
  cycles (37975 Hz, 19 %); the unit counter ends a unit exactly once in 6750 cycles
  (562.5 µs).

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
src/Icestick/Wave.wiz    waveforms, a software receiver, the simulator loop, test data
src/Icestick/Ir.wiz      NEC: specification, encoder (38 kHz carrier), decoder
src/Icestick/Blaster.wiz the IR blaster: command line, messages, the design
src/Icestick/IrSim.wiz   the transceiver and a remote in simulation, a waveform analyser
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
