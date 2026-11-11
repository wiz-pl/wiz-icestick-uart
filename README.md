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
| `ir` | the IR blaster: see below (`src/Icestick/Blaster.wiz`) | 1202 | 44 MHz |
| `oled` | the OLED demo for the PmodOLED (128 × 32): see below (`src/Icestick/Demo.wiz`) | 730 | 53 MHz |
| `oled64` | the same for a 128 × 64 SSD1306 module | 758 | 49 MHz |
| `oledrgb` | the OLED demo in colour for the PmodOLEDrgb (SSD1331, 96 × 64): see below (`src/Icestick/DemoRgb.wiz`) | 938 | 43 MHz |

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
sent 04 FB C4 3B (20DF23DC), echo ok
ir> power
sent 04 FB 08 F7 (20DF10EF), echo ok
ir> listen
listening, key stops
rx 04 FB 08 F7 (20DF10EF)
rx repeat
```

| command | sends |
|---|---|
| `on` | LG POWER ON: NEC address 0x04, command 0xC4 (discrete: switches on, never off) |
| `off` | LG POWER OFF: command 0xC5 (discrete) |
| `power` | LG POWER: command 0x08 (toggles; what the power key of an LG remote sends) |
| `raw AA CC` | NEC address `AA`, command `CC` (hexadecimal) |
| `raw AAAA CC` | extended NEC: the two address bytes in the order sent, no complement |
| `listen` | print every frame the receiver decodes, until a key is pressed |
| `help` or `?` | the list |

To try it: `.grail/bin/icestick flash ir`, then `screen /dev/ttyUSB1 115200` (leave with
Ctrl-A k y), point the end of the board opposite the USB plug at the TV and type `on`
or `power` and Enter. `.grail/bin/icestick irtest /dev/ttyUSB1` sends `on` and `power`
and checks both answers.

An answer gives the four bytes in the order sent (address, its complement, command,
its complement) and the 32 bits with the first bit sent on top, which is how LIRC,
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
units, 68 ms) is followed by a 40-unit gap; one frame per command, no repeat codes.

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

## The OLED demo

A demoscene-style demo on an SSD1306 OLED on the Pmod connector J2: a Digilent PmodOLED
(128 × 32), or with the design `oled64` a 128 × 64 module on the same pins. Four effects,
512 frames each (5.6 s), looping; each wipes in from the left over the one before:

| effect | what it is |
|---|---|
| plasma | four sine waves (along x, along y, along the diagonal, and along y bent by the first), summed, the middle of the range stretched to 16 grey levels, ordered dithering with the 4 × 4 Bayer matrix |
| stars | three layers of stars scrolling left at 1/2, 1 and 2 pixels a frame (parallax); the stars' rows come from a 64-entry table, read in a different order by each layer and each quarter of its 256-pixel strip |
| scroller | `WIZ ON ICE40` in an 8 × 8 font at twice the size, scrolling left a pixel a frame, every column moved up and down by a sine wave that travels along the screen, over the stars |
| XOR | the classic (u xor v) texture as grey levels, dithered, panning round a circle |

No frame buffer and no multiplier: the pixels are computed while the frame streams to
the display, one per clock cycle, eight into the byte the serialiser sends next, from
sine, star, message and font tables (logic, not block RAM: FINDINGS.md G19). The frame
rate is fixed at 12 MHz / 2^17 = 91.6 frames a second; a frame takes 1.4 ms of SPI at
6 MHz (16 cycles a byte, 512 bytes, plus 6 command bytes).

Serial port (115200 8N1, `screen /dev/ttyUSB1 115200`): `1` … `4` keeps one effect on
the screen (plasma, stars, scroller, XOR), `0` goes back to the sequence. LEDs: LED1 …
LED4 the effect on the screen, pulsing; LED5 (green) on once the display is.

**Pins** (`Oled.pins` in `src/Icestick/OledSim.wiz`; another module or wiring is a
change of numbers there):

| PmodOLED (J1) | signal | iCEstick J2 pin | FPGA pin | port |
|---|---|---|---|---|
| 1 | CS | 1 | 78 | `oled_cs` |
| 2 | SDIN (MOSI) | 2 | 79 | `oled_mosi` |
| 4 | SCLK | 4 | 81 | `oled_sclk` |
| 7 | D/C | 7 | 87 | `oled_dc` |
| 8 | RES | 8 | 88 | `oled_res` |
| 9 | VBATC (low: panel supply on) | 9 | 90 | `oled_vbatc` |
| 10 | VDDC (low: logic supply on) | 10 | 91 | `oled_vddc` |

(J2's pins 5, 11 are ground, 6, 12 3.3 V; pin 3, FPGA pin 80, is not driven.)

**Power-up** (`Prog.init` in `src/Icestick/Oled.wiz`, as the PmodOLED reference manual
and the SSD1306 datasheet ask): VDDC low, 1 ms; display off (AE); RES low for 1 ms
(at least 3 µs), RES high, 1 ms; D5 80, A8 1F (32 rows; 3F for 64), D3 00, 40, charge
pump on (8D 14), horizontal addressing (20 00), A1, C8 (upright), COM pins DA 02 (12 for
64 rows), contrast 81 CF, pre-charge D9 F1, VCOMH DB 40, A4, A6; the whole panel as the
window (21 00 7F, 22 00 03) and one frame of zeros (the screen cleared); VBATC low,
100 ms; display on (AF). Then, every frame: CS high until the frame tick, CS low, the
window again (six command bytes, D/C low), 512 data bytes (D/C high).

**Another module.** A 128 × 64 SPI module (the common 7-pin boards: GND, VCC, D0 = SCLK,
D1 = MOSI, RES, DC, CS) works with `oled64` on the same pins; it has its own supplies, so
VBATC and VDDC are left unconnected. An I²C module (4 pins: GND, VCC, SCL, SDA) needs a
different byte engine: `spiStep` is the only part that knows about SPI (the controller
gives it a byte and D/C when it is idle), so an I²C engine with the same interface
(address 0x3C, a control byte 0x00 or 0x40 instead of D/C) would replace it; it is not
written.

**Building and flashing.**

```sh
grail build oled            # the driver (and `grail build` checks the proofs)
.grail/bin/oled all         # gen (values, netlist, SSD1306 model, frames), sim, bit, postsim
.grail/bin/oled flash oled  # the PmodOLED (128 × 32); `flash oled64` for a 128 × 64 module
.grail/bin/oled look 32 300 1100   # the effects at frame counter values, as build/look/*.pbm
```

**How it is checked.** `oled gen` runs each design on values and on its netlist (they
must agree in every cycle) and feeds the pins to a model of the SSD1306
(`Model` in `OledSim.wiz`: SDIN shifted in on rising SCLK edges while CS is low and RES
high, D/C with the eighth bit, the datasheet's command table with its argument counts,
horizontal addressing into the RAM). It checks: VDD on at least 1 ms (`tVdd`) before the
first byte; the RES pulse at least `tVdd` and 3 µs; the command bytes exactly the
program's; VBAT after the reset and the display on at least `tVbat` after it; the
controller's registers as wanted (charge pump, rows, COM pins, addressing, window);
and every frame complete (512 bytes) and equal, pixel by pixel, to the effect evaluated
directly at the frame's time. `oled_fast` (waits of 40 and 200 cycles, a frame every
2^14 cycles, the frame counter stepping by 197) shows ten frames across all four
effects, the last after the host typed `3` (the scroller, whatever the time);
`oled64_fast` six frames on 64 rows. The frames are written as PBM pictures,
`build/frames/NAME_K_tT.pbm`. The board designs run the first 50000 cycles of the
power-up (the 100 ms wait alone is 1.2 million cycles). Icarus Verilog replays every
trace on the emitted Verilog and on yosys's netlist.

**What is proved** (`src/Icestick/Proofs/Oled.wiz`, by the kernel): the SPI serialiser
sends every byte as eight rising SCLK edges with SDIN the byte's bits, most significant
first, and is idle again in the 16th cycle, from either idle state (sixteen ranges of
sixteen bytes); `sin6` is its specification at all 64 phases; the program's memory
gives every entry of the program, for both panels, and the program fits it; the font's
memory gives every column; the power-up's command bytes, decoded by the datasheet's
command table, are complete and leave the controller as wanted (and so do the frame
headers after them); the power-up's steps are in the order the PmodOLED manual and the
SSD1306 datasheet ask, and the waits are at least 1 ms and 100 ms at 12 MHz.

## The colour OLED demo

The same demo on a Digilent PmodOLEDrgb: an SSD1331 controller, 96 × 64 pixels, 16-bit
colour (RGB 565), on J2 with the same pin numbers (J1 of the PmodOLEDrgb: 1 CS, 2 MOSI,
4 SCK, 7 D/C, 8 RES, 9 VCCEN, 10 PMODEN; VCCEN and PMODEN switch the supplies on when
high). `src/Icestick/OledRgb.wiz` (commands, program, controller), `FxRgb.wiz` (the
effects), `DemoRgb.wiz` (the design), `OledRgbSim.wiz` (pins, SSD1331 model, reference
frames, PPM).

| effect | in colour |
|---|---|
| plasma | the sum of the four sines through a rainbow palette (red, green and blue are three sines a third of a period apart), cycling |
| stars | the three layers: far ones dim and coloured, middle ones coloured, near ones white |
| scroller | `WIZ ON ICE40` in rainbow colours that run along the text, over the stars |
| XOR | (u xor v) through the palette, alternate bands at half brightness, panning round a circle |

Each effect gives a shade (black, palette, half palette, white) and a palette index per
pixel, and a single palette makes the colour, so the wipe between two effects is a
multiplexer. A pixel is two bytes (high first), computed when its first byte goes out; a
frame is 12288 bytes, 196608 cycles at 6 MHz (the SSD1331 allows 150 ns per bit), one
every 2^18 cycles (45.8 frames a second), the frame counter stepping by 2 so the effects
move as on the monochrome panel; 256 frames (5.6 s) per effect.

**Power-up** (`RProg.init`; PmodOLEDrgb reference manual: apply VCC, display off,
initialise, clear the screen, VCCEN, 100 ms, display on; the settings of Digilent's
driver): PMODEN high, 20 ms; RES low 1 ms (at least 3 µs), high, 1 ms; FD 12 (unlock),
AE, A0 72 (65k colours, column 95 at SEG0, COM backwards, odd/even split), A1 00, A2 00,
A4, A8 3F, AD 8E, B0 0B, B1 31, B3 F0, 8A 64, 8B 78, 8C 64, BB 3A, BE 3E, 87 06, 81 91,
82 50, 83 7D, 2E; the window 15 00 5F, 75 00 3F and a black frame; VCCEN high, 100 ms;
AF. Every frame: CS high until the tick, the window again, 12288 data bytes.

```sh
.grail/bin/oled all oledrgb oledrgb_fast   # simulate, check frames, synthesise
.grail/bin/oled flash oledrgb
.grail/bin/oled look rgb 108 539 1078      # colour pictures without the circuit
```

`oled gen` checks `oledrgb_fast` (waits of 50, 40 and 200 cycles, frames back to back,
the frame counter stepping by 539: frames 1 … 4 show stars and the scroller wiping in,
the XOR pattern, the plasma) through a model of the SSD1331 (the datasheet's command
table with its argument counts, every byte with D/C low a command byte; data bytes in
pairs into the window), and the first 270000 cycles of `oledrgb` (to the end of the
initialisation commands): the power-up order and times, the command bytes, the
controller's registers, and every pixel of every frame against the effects evaluated
directly. The frames are written as PPM pictures, `build/frames/oledrgb_fast_K_tT.ppm`.

## Ray tracing on the PmodOLEDrgb: `sphere` and `blobs`

Two more designs for the colour panel, with the same controller and pins
(`src/Icestick/Sphere.wiz`, `src/Icestick/Blobs.wiz`; `oled flash sphere`, `oled flash
blobs`; `oled look sphere T…` and `oled look blobs T…` render frames without the circuit).

* **`sphere`**: an orange ball (radius 20) orbiting and bouncing over a checkered floor
  that runs towards the viewer, with its shadow, under a dusk sky. Parallel rays; per
  pixel a 12-cycle serial tracer (while the pixel before is sent): shift-and-add squares
  of dx and dy, a bit-by-bit square root for the depth of the surface, Lambert shading
  2h − dx − dy. An exact ray–sphere intersection, no multiplier.
* **`blobs`**: a sphere tracer: two balls (radius 12) joined by a smooth minimum
  (quadratic, k = 8 pixels), swinging through each other so that they merge and split.
  A two-stage pipeline, one pixel per 32 cycles: stage A computes, for the pixel two
  ahead, each ball's ρ = |(dx, dy)| exactly (serial squares and square root, half-pixel
  precision); stage B marches the next pixel's ray, 16 steps, z += d, d from a
  conservative estimate of |(ρ, z − cz)| (max(ρ, |z − cz|, 11/16 (ρ + |z − cz|)), never
  more than the true length, exact where the ray passes closest to a centre, so the
  outlines are true circles) through the smooth minimum (its correction term from a
  17-entry table). Shaded by the nearer ball's normal; no floor (it did not fit).

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

Flashed `ir` (1202 of 1280 logic cells, 44 MHz), then over `/dev/ttyUSB1`:

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

### The OLED demo on the board (2026-11-11)

Flashed `oled` (commit 3d1fbbe; 730 of 1280 logic cells, no block RAM, 53 MHz by
nextpnr, 52 MHz by icetime) at 21:15 (+02:00): iceprog wrote and verified it. What the
display shows was not seen from here (no camera).

### The colour OLED demo on the board (2026-11-11)

The module turned out to be a **PmodOLEDrgb** (SSD1331, 96 × 64, 16-bit colour), not a
PmodOLED, so the demo was ported (`oledrgb`). Flashed `oledrgb` (commit dba7311; 938 of
1280 logic cells, no block RAM, 43 MHz by nextpnr, 40 MHz by icetime) at 21:49 (+02:00),
on J2: **the demo works on the real panel** (the user's report: the effects run in
colour). It was flashed before any simulation of it, at the user's request; the
simulations and proofs below were run afterwards.

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
src/Icestick/Oled.wiz    SSD1306: commands, power-up program, SPI serialiser, controller
src/Icestick/Fx.wiz      the demo's effects: sine, dithering, plasma, stars, scroller, XOR
src/Icestick/Demo.wiz    the OLED demo: effects, controller, LEDs, the key on the UART
src/Icestick/OledSim.wiz OLED pins, designs, an SSD1306 model, reference frames, PBM
src/Icestick/Proofs*     the proofs
app/icestick.wiz         the flow driver and the host-side test
app/oled.wiz             the OLED demo's flow driver
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
