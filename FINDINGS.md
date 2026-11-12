# Findings

What building this project showed about Wiz, its HDL library, grail, tower and the
system library, as of wiz `fe4e9c4` (2026-11-11). Each entry says what happened, a
minimal reproducer, and what the project does instead. Severity:

* **bug**: wrong behaviour;
* **gap**: something a hardware project needs and had to build or work around;
* **papercut**: works, but costs time.

Everything not written in Wiz is listed at the end.

**Since then (branch `wiz-nightly`, wiz bc84b49):** Wiz PR #91 (the HDL library's stage
H14 S1) addresses G1 (named ports: `uart_rx`, `uart_tx`, `leds`), G2 (one register per
field, named; wire names by `Hw.label`), G3 (bundles with `deriving Bundle`, `Circuit.seq`
and friends: the loopback is `seq tx (seq sync rx)`), G5 (`Circuit.withReset`,
`withEnable`), G6 (`Circuit.run` is tail recursive, the netlist interpreter O(n log n):
every trace is replayed in full), G7 (test bench, vector, VCD and PCF emitters in the
library), G8 (`Circuit.design : Design`, a `Type`: the designs are a `List Design`) and G9
(the helpers are `Hdl.*`); PR #81 fixed B1 and B2, so the local Verilog emitter is gone.
G4 remained (numerals at hardware types), and G10 (a literal as first argument of
`Hw.cat`).

**Since then (branch `hdl-api-108`, wiz b6ad475):** Wiz PR #92 fixed G10 in the
elaborator, and PRs #108 and #118 removed the HDL library's workarounds for it: `BStep`
is gone (`Circuit.bundled` takes the step function itself, `(echoStep n)`), `Hw.cat
(Hw.lit 1 1) d` needs no ascription, and `board` takes the TX line first. G4 remains.
The text below describes the state at fe4e9c4.

**Since then (branch `cleanup-ops`, wiz 50cd3e7):**

* **G4 is fixed** by Wiz PR #202 (H14 S2): numerals at signal width, `+ - *`, `&&& |||
  ^^^ ~~~`, `=== =/= <ᵤ ≤ᵤ >ᵤ ≥ᵤ`, and `if` on a one-bit signal as a multiplexer. Every
  step function is now written with them: `if go then 10 else if tick then s.left - 1
  else s.left` instead of `Hw.mux go (Hw.lit 4 10) (Hw.mux tick (dec s.left) s.left)`.
  The project's helpers `band bor bnot eqLit inc dec` are gone; `lo`/`hi` stay where a
  bit is an argument (`Hw.cat lo …`). The operators are the `Hw` operations, and the
  rewrite keeps every expression's shape (`a &&& (b &&& c)` where the old text had
  `band a (band b c)`), so the Verilog of every design is byte-identical to before.
  Constants from meta-level numbers are `Hw.ofNat (n - 1)`. Where both branches of an
  `if` are literals and nothing else fixes the width, the first one stays `Hw.lit w k`.
* **B6 (bug, elaborator, #202's `if`). Some `if`s on signals do not elaborate without a
  type.** Three cases came up, all fixed by giving a type:
  * The first field of a parametrised bundle's constructor is an `if`:
    `Ctl.pack c.frameLog (Ctl.mk (if ready &&& opAgain then Hw.lit 6 … else …) …)`
    fails with "unification problem is outside the pattern fragment" (the expected type
    is a hole applied to every local). An ascription works around it:
    `(Ctl.mk … : Ctl c.frameLog r)`. The same holds for `RCtl.mk`. `Tx.mk (if go then 0
    else …)`, where the bundle has no parameter, works.
  * `let fl := if light then rgb565 … else rgb565 …` (both branches are calls whose
    representation `r` is implicit) fails with "a variable escapes the scope of the hole
    being solved", and the variable that escapes is the condition, `light`. It works
    with `let fl : r (HwTy.bits 16) := …`.
  * `let waitLen := if code === 5 then Hw.lit 21 a else if code === 4 then Hw.lit 21 b
    else Hw.lit 21 c` fails with "outside the pattern fragment". It works with a type on
    the `let`.
  `Hw.mux` gives none of these problems: its type arguments come from the call. The
  rewrite has five such type annotations (`Oled.ctlStep`, `OledRgb.rctlStep` twice,
  `Sphere.backdrop` twice).
* **B5 is fixed** by Wiz PR #200 (reuse across `case` was exponential in a structure's
  fields). The IR blaster's state is still grouped into `Ed`, `Pt` and `Fr`, for two
  reasons. The groups read well (editor, printer, frame). And flattening them would
  rename 13 of the blaster's registers in the Verilog (`ed_len` becomes `len`), which
  would break the byte-for-byte comparison this cleanup is checked by.
* **Still to do, waiting for Wiz PRs that are not merged:**
  * #225 (H14 S4): signed comparisons (`Blobs.slt12` flips the sign bits and compares
    unsigned; `<ₛ` would replace it), `&&`/`||` on one-bit signals, shifts by a signal
    (`pickBit`, `bitAt` and `pick8` are multiplexer trees by hand), `deriving BitPack`
    (the IR blaster's message codes and the CPU's opcodes are `Nat` constants compared
    with `===`), and `Circuit.registerR` (the designs have no reset: G5).
  * #199 (`Hdl.Sim.simFast`): `icestick gen` and `oled gen` simulate with
    `Design.runLeaves` and `Netlist.simulate`. The long scenarios take most of an hour
    on a busy machine, and `blobs` is not simulated at all. `simFast` is about 25 times
    faster on `oled_fast`.

## Bugs

### B1. Verilog: use before declaration (HDL library)

`Verilog.emit` prints a register's update before the wire it reads is declared:

```verilog
module blinky(input clk, input [0:0] x, output [5:0] y);
  reg [23:0] r0; initial r0 = 0;
  always @(posedge clk) r0 <= n8;      // n8 is declared ten lines below
  wire [0:0] n0 = x;
```

yosys accepts this; Icarus Verilog 13 does not ("Unable to bind wire/reg/memory `n8'
... Check for declaration after use"). Reproducer: `Verilog.emit (Circuit.netlist "c"
counterC)` from `examples/hdl.wiz`, through `iverilog`.
Here: `Emit.verilog` in `src/Icestick/Board.wiz` prints registers, wires, then the
updates. Upstream: wiz pull request #81 (with a test that feeds the emitted Verilog to
iverilog when it is installed); the local emitter can go when the toolchain pin moves
past that fix.

### B2. Verilog: unsized initial value (HDL library)

`initial r0 = 13835062455471964160;` for a 64-bit register. An unsized Verilog literal
is only guaranteed 32 bits. yosys 0.70 and iverilog 13 keep all the bits, so nothing
went wrong here, but the TX line's idle level lives in the top bits of that register.
Same fix as B1 (`64'd…`), same pull request.

### B3. `let ω x := e` in a `do` block ends after the next statement

```
import Sys
def a (d : Nat) : EIO Unit := do
  let ω name := d + 1;
  EIO.lift (IO.println (Nat.toString name));
  EIO.lift (IO.println (Nat.toString name))     -- error: unknown identifier 'name'
```

With a plain `let name := d + 1;` both uses are in scope. Here: plain `let` in `do`
blocks.

### B4. Structural recursion is rejected depending on the order of the matched arguments

```
def allBelow : Nat → (Nat → Bool) → Bool
  | .zero, p => .true
  | .succ n, p => Bool.and (p 0) (allBelow n (fun (k : Nat) => p (Nat.succ k)))

def spec : (n k : Nat) → (p : Nat → Bool) → allBelow n p = .true → Nat.lt k n = .true → p k = .true
  | .zero, .zero, p, h, hk => absurd hk.1
  | .zero, .succ k, p, h, hk => absurd hk.1
  | .succ n, .zero, p, h, hk => Bool.and_left (p 0) (allBelow n (fun (j : Nat) => p (Nat.succ j))) h
  | .succ n, .succ k, p, h, hk =>
    spec n k (fun (j : Nat) => p (Nat.succ j))
      (Bool.and_right (p 0) (allBelow n (fun (j : Nat) => p (Nat.succ j))) h) hk
```

fails with `expected: ?m2 n k p a3 a4 n✝ _ih k p a3 a4 n✝ p a3 a4 _ih / inferred: n✝
(rigid mismatch)` at the recursive call. The same definition with the first two
arguments swapped (`(k n : Nat)`, the clauses reordered to match) checks. Here:
`allBelow_spec` in `src/Icestick/Proofs.wiz` takes `k` first.

## Gaps in the HDL library

### G1. One anonymous input bus, one anonymous output bus

A `Circuit i o` becomes `module m(input clk, input [..] x, output [..] y)`. The board
has named pins. Here the pin constraints address bits of the buses (`set_io y[0] 8`),
and `outPack` documents which bit is which. That worked without a hand-written Verilog
wrapper, but only because yosys and nextpnr accept `x` for a one-bit bus and `y[k]`.
Wanted: named ports (a record of inputs, a record of outputs), and the constraint file
derived from them.

### G2. All state in one register, all wires numbered

The state of `proto` is `reg [63:0] r0`, and every wire is `nK`. Timing reports, yosys
warnings and waveforms cannot be related to the source. Wanted: one register per leaf
of the state type, named after it, and wire names from `let` binders where there is one.

### G3. No composition, no records of state

A design made of a synchroniser, a receiver, a transmitter and its own registers
(`protoStep`) is one step function over a nested pair, taken apart by hand:

```
let lines := Hw.snd (Hw.snd (Hw.snd (Hw.snd (Hw.snd (Hw.snd s)))));
```

and put together again in the same order at the end. Seven components is about the
limit of what one can keep straight. Wanted: either state as a structure
(`BitPack`-derived, as in the HDL plan) or circuit combinators that hide the state of
the parts (`Circuit.seq`, feedback, instances with local state).

### G4. No numerals, operators or conditionals at hardware types (fixed: Wiz PR #202)

`Hw.mux go (Hw.lit 4 10) (Hw.mux tick (Hw.sub left (Hw.lit 4 1)) left)` for
`if go then 10 else if tick then left - 1 else left`. (Numeric classes for bit vectors
are on their way; a `mux` notation is not.) Phases of the state machines are numbers
compared with literals (`eqLit ph 10`) because there is no enumeration at `HwTy`.

### G5. No reset, no clock enable

Registers start from `initial` values. That is right for an iCE40 (yosys turns a
non-zero initial value into inverters around a flip-flop that starts at 0; the
post-synthesis simulation and the board confirm it), and wrong for most other targets.

### G6. Simulation does not scale as written

`Circuit.run` is not tail recursive, and `Netlist.simulate` appends to the list of
values per node (quadratic in the number of nodes per cycle). Traces here are 200000
cycles. Here: `Sim.run` (`src/Icestick/Wave.wiz`) and `NetSim.run`
(`app/icestick.wiz`) with accumulators; the netlist is only replayed for the first
6000 cycles of each trace (the Verilog simulators replay all of it).

### G7. No test bench, trace or constraint emitters; no `wiz hdl`

`Board.testbench`, `Vec.chunk` and `Board.pcf` are strings assembled in this
repository; the Verilog comes out of a program's `main`, because `#eval` output is a
quoted string in a message. The test bench is Verilog, but generated: there is no
hand-written Verilog file in the repository.

### G8. `Circuit` lives in `Type 1`

`Circuit i o` quantifies over the representation, so it is not a `Type`, and `List`
takes a `Type`: no list of designs, no structure with a circuit in it kept in a list
(`error: type mismatch, expected: Type, inferred: Type 1`). Here: an enumeration
`Design` and a function `Design.circuit`.

### G9. `Hdl.Core` brings general names with it

`import Hdl.Core` defines `List.map`, `List.nthD`, `List.reverseAux`, `Nat.show`,
`NatList.beq` and the infix `<+>`, and (through `BitVec` and `Word`) owns `U8`, `U16`,
…, so the obvious names for hardware types are taken (`error: 'U8' has already been
declared`; the types here are `B8`, `B9`, …).

## Gaps in the language and the elaborator

### G10. A literal as first argument does not elaborate

**Fixed** by Wiz PR #92 (the library's workarounds removed by PRs #108 and #118; this
project drops its ascriptions on branch `hdl-api-108`). The second example below was not
re-checked.

```
def frame9 {r : HwTy → Type} [Hw r] (d : r (HwTy.bits 8)) : r (HwTy.bits 9) :=
  Hw.cat (Hw.lit 1 1) d
-- error: type mismatch  expected: ?m0 r inst✝ d (.bits (?m2 r inst✝ d))
--                       inferred: ?m4 r inst✝ d (.bits 1)
--        (unification problem is outside the pattern fragment)
```

The representation of `Hw.lit` is not known yet when the first argument is elaborated,
and `?r (.bits ?n) =?= ?r' (.bits 1)` is not attempted first-order. The same happens
with any helper that returns `r t` and takes no `r` argument (`hi : r Bit`) in first
position. Here: `(Hw.lit 1 1 : r (HwTy.bits 1))`, and helpers take the data argument
first (`shiftIn9 sh hi`).

Where a first-order guess *is* made, it can be the wrong one:

```
def inRange (base : Nat) (h : allBelow 16 (fun (j : Nat) => ok (base + j)) = .true)
    (k : Nat) (hk : Nat.lt k 16 = .true) : ok (base + k) = .true :=
  allBelow_spec k 16 (fun (j : Nat) => ok (base + j)) h hk
-- error: type mismatch   expected: ?m0 base h k hk   inferred: k
```

(the expected type `ok (base + k)` against `?p ?k` was solved with `?k := base + k`
before the explicit arguments were looked at). Here: the predicate has a name
(`Loop.at8 base`).

### G11. The kernel is slow and keeps everything while it runs a circuit

Measured with the loopback circuit (transmitter, synchroniser, receiver: about 100
netlist nodes) at `HwTy.El`:

* **Speed**: about 30 cycles per second. `Loop.ok 104 1100 b = .true := refl .true`
  (one byte at the board's divider) takes 33 s. All 256 bytes would take 2.5 hours.
* **Memory**: about a megabyte per simulated cycle until the declaration is finished.
  `allBelow 256 (Loop.ok 8 90) = .true := refl .true` (23000 cycles) passed 4.5 GB
  after 20 s and was killed.
* **No gluing**: a statement `x = .true` is evaluated again wherever it is used.
  `allBelow_append m n p h1 h2 : allBelow (m + n) p = .true` from two checked ranges
  `h1`, `h2` ran both ranges again (31 s for 8 bytes whose two halves were already
  checked), so sixteen small statements cannot be combined into one for all 256 bytes
  without paying the time and memory of the big one. Stating the facts as
  `IsTrue b := match b with | .true => True | .false => False` made no difference.

So: `src/Icestick/Proofs/Board.wiz` proves the loopback for four bytes at 104 cycles
per bit; `Proofs/Loopback.wiz` and `Loopback2.wiz` prove it for all 256 bytes at 8
cycles per bit, as sixteen statements of sixteen bytes; and the compiled program does
all 256 at 104 in about a second (`tests/loopback.wiz`). Wanted: a `refl` that may run
compiled code, or a kernel evaluator that shares and frees, and a conversion check that
compares two syntactically equal types before evaluating them.

### G12. No conditional expression, no string or list basics without `Std`

No `if`; `String.eq`, `String.contains`, `String.toNat`, `List.take` are defined in
`app/icestick.wiz`. (`Std` may have some of them; importing it next to `Hdl.Core` was
not attempted because of G9.)

## Gaps in the system library (lib/Sys)

### G13. No serial port: no termios, no bytes on a handle, no time limit on a read

* The port is configured by running `stty` (`setupPort`).
* A `File` reads and writes `String`s, and a string cannot carry a NUL (and bytes above
  127 are not one character). `Bytes` exists, but only for whole files
  (`FS.readBytes`/`FS.writeBytes`), which is no use on a terminal. So the hardware test
  written in Wiz only sends bytes 1 … 127, and the protocol's answer is ASCII. The
  simulations send all 256 values; on the board, all 256 values were checked with the
  `echo` design and `cat`/`cmp` (README).
* A read cannot time out. The time limit of the test is the terminal's (`stty min 0
  time 20`), which makes a read return nothing, which the C library reports as the end
  of the file.

Wanted: `File.readBytes h n`, `File.writeBytes h b`, a read with a time limit, and
termios (now possible as a C shim: `link_c` was merged after the pinned toolchain).

## Gaps in grail

### G14. grail cannot run a command

Targets are libraries, checks, executables and tests. Synthesis, place and route,
simulation and flashing are commands with inputs and outputs, exactly what grail's
job graph is for, but there is no way to say so. Here: grail builds one executable,
`icestick`, which runs the tools with `Process.run` and has no notion of what is up to
date (it redoes everything, which takes seconds). No Makefile and no shell script.
Wanted: a `Package.command`/rule target (inputs, outputs, command line), and
`grail run NAME ARGS…`.

### G15. Jobs that die, and other small things

* A check job that is killed (here: by a memory limit) is reported as
  `✗ check src/Icestick/Proofs/Loopback.wiz` followed by an empty message.
* When grail itself is killed (`timeout 60 grail build`), its job processes
  (`grail --grail-job …`) keep running.
* A check that runs for minutes (G11) prints nothing until it ends.
* A library target and an executable target may have the same name, and
  `grail build NAME` then builds both.

## The IR blaster (branch `ir-blaster`, wiz b6ad475)

* **G16 (gap). A design that fits in the step function may not fit in the FPGA, and
  nothing says so before nextpnr.** The first version of `ir` took 1411 of 1280 logic
  cells. Two things cost most: comparisons with a constant (`Hw.ult x (Hw.lit n k)`)
  become carry chains in yosys (a logic cell per bit; 281 `SB_CARRY` cells: the
  decoder's duration thresholds, the hex-digit tests), and the message ROM written as a
  chain of `mux (eq idx k)` (430 LUTs for 252 entries; a tree on the address bits is
  300). The fixes are in the design: threshold flags set at `dur == k - 1`, bit tests on
  characters, 7-bit ROM entries, shorter messages, and no second copy of the frame
  (the encoder reads the bit it needs from the register the answer is printed from;
  the decoder shifts into it and compares bit by bit): 1202 cells. A size estimate
  in the HDL library (count of comparisons with constants, ROM bits) would have caught
  it earlier; the BRAMs (16 × 4 kbit, unused) would hold the ROM, but the library has
  no memory primitive.
* **G17 (gap). The value simulation is strict, so every wire costs every cycle.** A ROM
  as a balanced tree of multiplexers (better for yosys) made the value simulation
  several times slower than the chain, because `HwTy.El` evaluates both sides of each
  `mux` and the tree's leaves are cut out of the list again each cycle. The design
  keeps the chain. A ROM primitive (`Hw.rom : List Nat → r (bits a) → r (bits w)`,
  a table lookup at values, a `case` or a BRAM in Verilog) would serve both.
* **G18 (gap). `grail test` gives every test 60 s, fixed** (Grail/Test.lean). Half a
  million cycles of the blaster, or one frame of the encoder at the board's timing (1.1
  million cycles), do not fit, so those checks live in `icestick gen` and the test uses
  the faster timing. A per-test limit (`-- test: run 600`) would do.
  **Known flake (wiz 50cd3e7):** tests/ir.wiz itself is now close to the limit. It ran
  for about 51 s from the old source and about 54 s from the operator rewrite (two runs
  each, under `heavy` on a shared machine, so informal), and one `grail test` run on
  `cleanup-ops` timed out at 60 s. Grail at the pinned commit has neither a
  `--test-timeout` flag nor a per-test setting (`timeout 60` is hard-coded in
  Grail/Test.lean), so the limit cannot be raised here. To fix when re-pinning: raise the
  limit for this test once grail supports it, or split tests/ir.wiz into smaller tests.
* **Observation (not about Wiz): an LG TV acts on its power toggle only when the key
  is held.** On the TV tested, `on` (0xC4) and `off` (0xC5) worked as a single NEC frame;
  `power` (0x08) did nothing as a single frame and toggled the TV as a frame followed by
  four repeat codes (0.54 s), 2026-11-11 21:45:41. Code lists give the codes but not
  this; the design sends the repeats for `power` by default.
* **B5 (bug, performance; fixed by Wiz PR #200). A step function over a bundle with many fields compiles
  very slowly.** With 19 fields in `Blaster` (five of them nested bundles), `#ir
  blasterStep` took more than 5 minutes and grail's `ir` job for the driver more than 30
  (it hit grail's job limit); `#ir Blaster.pack` alone took 25 s. Grouping the same
  registers into three sub-bundles (`Ed`, `Pt`, `Fr`: 8 fields at the top) brought
  them to 21 s and 6 s, and the driver to minutes. Splitting the step into smaller
  functions (`keyStep`, `parseLine`, `prnStep`) alone did not help. A synthetic repro
  is in /workspace/wiz-notes/perf-repros/struct19.wiz (18 s, against 7 s for
  struct19-grouped.wiz).
* **P6 (papercut). `IrCfg.board.unit` does not parse as "field `unit` of the constant
  `IrCfg.board`"** ("no field 'board' in a value of type Type"); `IrCfg.unit IrCfg.board`
  works, and so does `cfg.unit` on a variable.
* **P7 (papercut). Compiling the driver took about twelve minutes** with the IR
  scenarios, before B5 was worked around (grail's cache makes the second build instant).

## The OLED demo (branch `oled-demo`, wiz b6ad475)

A demo for an SSD1306 OLED (Digilent PmodOLED, 128 × 32) on the Pmod connector:
`src/Icestick/{Oled,Fx,Demo,OledSim}.wiz`, `app/oled.wiz`, README "The OLED demo".

* **G19 (gap). No memory primitive, so no block RAM.** The brief suggested sine and font
  tables in BRAM (the HX1K has 16 × 4 kbit, all unused). The HDL library has no way to
  say "memory", and yosys does not turn the emitted multiplexer trees into one. So the
  tables are logic: the program (49 × 9 bits), a quarter-wave sine (16 × 4), the star
  table (64 × 7), the message (16 × 4) and the font (80 × 8), as balanced trees on the
  address bits with constant subtrees folded (`Rom.at`). That turned out cheap: the
  whole design is 727 logic cells. A larger font or a frame buffer would need
  `Hw.rom`/`Hw.ram` (a table lookup at values, `$mem`/`SB_RAM40_4K` in Verilog), as G16
  and G17 asked.
* **G20 (gap). The value simulation runs about 2000 cycles a second** for this design
  (1068 netlist nodes; 20000 cycles in 10 s, compiled); the controller alone runs at
  about 7000. A frame of the 128 × 32 panel is 512 bytes, 8192 cycles at 16 per byte, a
  frame every 16384 cycles in the simulation's configuration: eight seconds each, so
  `oled gen` simulates ten frames of `oled_fast` in about two minutes. Building the
  tables' trees once instead of in every cycle (`RomT`, after G17) made no measurable
  difference: the time is in the operations at `HwTy.El` themselves (bit vectors as
  `UIntN`, bundles packed and unpacked every cycle). Wanted: a step function compiled to
  machine words for simulation.
* **G21 (gap). Kernel proofs about the serialiser are cheap only in small pieces.** "Every
  byte is sent right" (256 bytes × 2 idle states × 16 cycles of a 20-node circuit) as one
  `refl` passed 4 GB and was stopped; as sixteen ranges of sixteen bytes (the pattern of
  `Loop.range_*`) it checks. G11 again.
* **B5 (bug, this project's). A memory tree over a list shorter than 2^k was wrong**:
  `Rom.allEq` on a short last subtree saw only the entries present and folded the whole
  subtree to the last entry. The kernel proof `RomP.board32` (every address of the
  program's memory gives the program's entry) found it; the simulations could not, since
  the program never reaches those addresses. Fixed by padding with zeros.
* **P8 (papercut). No record update, no numeral patterns, no list literals.**
  `{ s with on := .true }` does not parse, `| 0, 0 =>` is not a pattern, and every list
  is a chain of `.cons`. The SSD1306 model keeps its 21 registers in a `List Nat` with
  named indices instead of a structure, and the program is built from small lists
  appended. (`if … then … else` does exist now, in `Prelude`; G12 is out of date.)
* **P9 (papercut). Error messages around a long `.cons` chain mislead.** One parenthesis
  too many in a 30-line chain gave "type mismatch: expected List Step, inferred List
  Step → List Step" at its start and "expected 'def', …" in its middle; uses of a
  definition that failed to elaborate report "no field 'go' in a value of type Type"
  (like P6) rather than "this definition has errors".

* **The colour port (`oledrgb`, SSD1331).** The module was a PmodOLEDrgb after all.
  The port reused the serialiser and the effects' building blocks unchanged; the
  controller's state is five small bundles (sequencer, pins, frame timing, pixel
  position, serialiser) instead of one structure of thirteen fields, following the IR
  project's experience that large structures make the compiler crawl. It was written,
  synthesised (938 cells) and flashed in about an hour, **without any simulation, and
  worked on the panel the first time**. The datasheet-level program (a list of named
  steps and commands) and the reuse of the parts that the monochrome design had already
  had simulated and proved carried it. A frame of 12288 bytes is 196608 cycles: at G20's
  2000 cycles a second, eight minutes of value simulation for four frames, the same
  again on the netlist; so `look rgb` (the effects evaluated directly) was what was used
  to judge the colours.

* **Ray tracing (`sphere`, `blobs`).** Both were written, fitted and flashed without a
  circuit simulation; `oled look sphere|blobs` (the step functions evaluated pixel by
  pixel at `HwTy.El`, a frame in seconds) was the check before each flash, and it
  caught real problems: the first `blobs` used an octagonal 3-D length estimate and
  drew octagons, and shaded from the march's depth, which that estimate gets wrong, so
  the highlights were huge blocks. `blobs` went through six place-and-route rounds
  (1717 → 1538 → 1372 → 1230 → 1269 → 1282 of 1280 cells) to fit: G16 again, with no
  estimate before nextpnr. What fitted: one distance unit shared by the two balls (two
  cycles a step), the per-pixel part of the length computed exactly once per pixel in
  a separate pipeline stage, tables for the smooth minimum's square and the sphere's
  front, and no floor. Hw.mul was never used: at these widths it would not fit.
* **G20, later.** Wiz PR #199 (agent hdl-sim-perf) adds `Design.simFast`
  (`lib/Hdl/Sim.wiz`), about 25 times faster on `oled_fast` with the same results as
  the value simulation. This project is pinned to b6ad475 and still uses
  `Design.runLeaves`: `oled gen oledrgb_fast` (a million cycles) takes about half an
  hour. Moving the pin past #199 is the obvious next step.
* **P10 (papercut). `pkill -f PATTERN` from a shell whose command line contains the
  pattern kills that shell** (AGENTS.md warns about it; it happened once here).

## Papercuts

* **P1. Error messages are not bounded.** A mismatch that involves an equation between
  two 104-element lists printed the equation's computed form: one message of 40 KB of
  `(0 e'''''… : True) ×`.
* **P2.** `Eq.trans p q` could not find its end points when `q` was a (computed)
  equation of lists; `@Eq.trans (List Nat) a b c p q` was needed.
* **P3.** `wiz check -I src file.wiz` prints nineteen warnings "builtin nat := Nat is not
  checked: it is an axiom of every declaration …", each prefixed by the chain of
  imports that leads to `Prelude`, on every run.
* **P4.** Nix: the Cachix cache only helps a trusted Nix user; otherwise `nix develop`
  builds wiz from source (two to three minutes here).
* **P5.** `iceprog` needs write access to the USB device (a udev rule), and leaves the
  first serial device (`ttyUSB0`, the SPI channel) unbound until the board is plugged
  in again. Not Wiz's doing, but a stranger will meet it (README).

## The toy CPU (branch `toy-cpu`, wiz b6ad475)

Found while adding the processor of docs/cpu.md.

### C1. No memories in the HDL library (gap)

There is no memory primitive (`NetOp` has registers, no arrays), so neither a ROM nor a
RAM can be asked for and nothing becomes an iCE40 block RAM. The program ROM is a chain
of multiplexers over constants (`romW`), the eight bytes of data memory are 64
flip-flops with an 8-way read multiplexer and eight write enables. That is fine at this
size and would not be at 256 bytes of RAM. It also means a program is part of the
bitstream: one synthesis per program, where a block RAM's contents could be replaced in
the bitstream (`icebram`) or loaded over the UART. Wanted: `Hw.rom (contents) addr`
and a synchronous RAM, emitted as Verilog arrays that yosys maps to SB_RAM40_4K.

### C2. Proving a circuit against a specification: what `rfl` can and cannot see (gap)

`Cpu.core_ok` proves `coreStep` (at values) equal to `Spec.exec` with the state symbolic.
It goes through by `rfl` only because of two rules the circuit had to follow:

* A data-dependent bit may only be a multiplexer select. `Hw.and (Hw.lit 1 0) x` with a
  symbolic `x` does not reduce (it is `UIntN.mk (Nat.land 0 x.toNat)`), so a stall
  signal written `isOut & !txReady | isIn & !rxFull | isHalt` stays stuck even when the
  opcode is known; written `mux isOut txReady (mux isIn rxFull (!isHalt))` it reduces.
  The first form is the one a hardware designer writes.
* The specification has to use the same multiplexer: a conditional on a symbolic bit
  must be `HwTy.El.mux c x y` on both sides (`Spec.pick`), or the two stuck terms differ.

So the proof shows the decoder, the selections and the enables right, but the shape of
the circuit is constrained by what the kernel's evaluation happens to normalise.
Wanted: simplification lemmas for `BitVec` at width 1 (`and 0 x = 0`, `or 1 x = 1`,
`mux c x x = x`, …) usable by a rewriting tactic or by the conversion check, or a
bit-blasting decision procedure for small widths.

### C3. No numeric literals in patterns (papercut)

`match n with | 0 => … | 1 => …` is `error: invalid pattern (term.num)`. The decoder of
the specification matches opcodes 0 … 13 as `.succ (.succ (… .zero))`, up to fourteen
deep (`Spec.decodeN`), and so does the proof's case split.

### C4. No list literals (papercut)

Programs are lists of instructions; without `[a, b, c]` they are `.cons` chains.
`src/Icestick/Asm.wiz` declares `infixr:67 " :: " => List.cons`, which works.

### C5. A conditional generic in the type cannot be applied at `BitVec 8` (papercut)

`def Spec.pick {ω t : HwTy} (c : BitVec 1) (x y : HwTy.El t) : HwTy.El t` applied to
`BitVec 8` arguments fails with `expected: HwTy.El ?t, inferred: BitVec 8 (unification
problem is outside the pattern fragment)`: `HwTy.El` cannot be inverted, as expected,
but every specification over values meets it. Here: a `BitVec 8` version.

### C6. `let ω x := match … ; body` without a type does not elaborate (bug)

```
def Q.size (n : Nat) : List String :=
  let ω s := match Nat.lt 256 n with
    | .true => List.cons "big" List.nil
    | .false => List.nil;
  List.append s s
-- error: type mismatch  expected: ?m0 n  inferred: List (?m1 n x✝)
--        (a variable escapes the scope of the hole being solved)
```

The match's element type is solved inside the alternative, where the matched value is in
scope. Here: a helper function (`Asm.tooLong`).

### C7. The kernel evaluates a recursive call inside a `match` exponentially (bug)

```
inductive T where
  | a (s : String)
  | b
  | c
def f : Nat → List T → Nat
  | k, .nil => k
  | k, .cons t ts => match t with
    | .a s => f k ts
    | _ => f (Nat.succ k) ts
def p : List T := .cons T.b (.cons T.b … .nil)   -- n elements
def X : f 0 p = n := rfl
```

n = 12: 0.35 s, 85 MB; n = 16: 1.1 s, 140 MB; n = 20: 11 s, 910 MB (`wiz check`, one run
each on a shared machine: rough numbers, but the growth is unmistakable). Explicit
alternatives instead of `_`, or the same argument in both recursive calls, make no
difference. With the recursive call outside the match (`List.append (here k t) (f (k +
size t) ts)`) it is linear. Compiled code and `#eval` are not affected: the assembler's
`Asm.labels` was written the first way, `#eval Asm.assemble` answered at once, and
every proof that ran a program of 18 or more instructions went over 5 GB. Here:
`Asm.labels` in the linear form (`Asm.here`, `Asm.size`).

### C8. A test without `-- test: run` fails without saying why (papercut, grail)

`tests/cpu.wiz` without the directive line was reported as `✗ tests/cpu.wiz` with
"expected: (the first line of cpu.expected), actual: (nothing)": nothing was checked,
compiled or run, and nothing said that the directive was missing.

## Not verified

* **The pin numbers** are those of icestorm's `examples/icestick/icestick.pcf`
  (clk 21, RX 9, TX 8, LED1 … LED5 = 99 … 95); the IrDA pins (TXD 105, RXD 106, SD 107)
  are from Lattice's iCEstick user guide (EB82, table 2) and confirmed by the board:
  the decoder reads back each frame the encoder sends. The clock, RX and TX pins are confirmed by the
  board answering; nobody has looked at the LEDs yet.
* **tower** was only tried as far as installing the toolchain named by
  `wiz-toolchain` (`tower toolchain install`, Nix source, into a private `--home`) and
  running `grail targets` with it: no problems. The builds here used the flake.

## What is not written in Wiz, and why

| What | Instead | Why |
|---|---|---|
| Synthesis, place and route, bitstream, timing, programming | yosys, nextpnr-ice40, icepack, icetime, iceprog, run by the Wiz driver | not Wiz's job |
| Verilog simulation | Icarus Verilog, run by the Wiz driver; the test bench is generated by Wiz | an independent simulator is the point |
| Serial port setup | `stty`, run by the Wiz driver | G13 |
| The all-byte-values check of `echo` on the board | `cat`, `cmp` by hand (README) | G13 |
| A pseudo-terminal pair for the fake board | `socat`, by hand (README) | no pty API |
| The environment | `flake.nix` | |
| CI | a GitHub workflow | |

There is no shell script, Makefile, C, Python or hand-written Verilog in the repository.
