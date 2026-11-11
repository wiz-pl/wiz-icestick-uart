# A toy CPU

A minimal processor for the iCEstick, written with the same HDL library as the UART:
an 8-bit accumulator machine with fourteen instructions, eight bytes of data memory,
the five LEDs and the serial port. It is meant to be read in an afternoon.

```
src/Icestick/Cpu.wiz           the architecture (Spec.*) and the hardware (coreStep, cpu)
src/Icestick/Asm.wiz           the assembler and the example programs
src/Icestick/Proofs/Cpu.wiz    hardware = architecture; the ROM; small program proofs
tests/cpu.wiz                  the example programs in simulation
```

## The machine

| register | width | |
|---|---|---|
| `PC` | 8 | address of the next instruction (programs of up to 256 instructions) |
| `A` | 8 | the accumulator: every computation goes through it |
| `M[0]` … `M[7]` | 8 each | the data memory |
| `LEDS` | 5 | LED1 … LED5 (bit 0 … bit 4) |

An instruction is a 12-bit word: a 4-bit opcode and an 8-bit operand `k`. For the
memory instructions the operand is an address (its low three bits, `a`); for jumps it
is the target `t`.

| op | mnemonic | effect | then |
|---|---|---|---|
| 0 | `halt` | nothing | PC stays: the machine stops |
| 1 | `ldi k` | A ← k | PC + 1 |
| 2 | `ld a` | A ← M[a] | PC + 1 |
| 3 | `st a` | M[a] ← A | PC + 1 |
| 4 | `addi k` | A ← A + k | PC + 1 |
| 5 | `add a` | A ← A + M[a] | PC + 1 |
| 6 | `sub a` | A ← A − M[a] | PC + 1 |
| 7 | `nand a` | A ← ¬(A ∧ M[a]) | PC + 1 |
| 8 | `jmp t` | | PC ← t |
| 9 | `jz t` | | PC ← t if A = 0, else PC + 1 |
| 10 | `jnz t` | | PC ← t if A ≠ 0, else PC + 1 |
| 11 | `out` | send A over the UART | PC + 1; waits while the transmitter is busy |
| 12 | `inp` | A ← the next byte received | PC + 1; waits until a byte has arrived |
| 13 | `led` | LEDS ← A[4:0] | PC + 1 |
| 14, 15 | | as `halt` | |

Arithmetic is modulo 256. There are no flags: `jz`/`jnz` look at A itself. The
machine starts with everything zero. A byte that arrives while an earlier one is still
waiting replaces it (a one-byte buffer).

### Why these

* **An accumulator, not registers.** One register means no register fields in the
  instruction and one write port; with a 4-bit opcode an 8-bit operand fits in 12
  bits, enough for any byte constant and any of 256 addresses.
* **Eight bytes of memory** are enough for three nested loop counters and some
  variables; they are 64 flip-flops and two 8-way multiplexers. The address is the low
  three bits of the operand, so the encoding has room to grow.
* **`nand`** is the one logic instruction: with `ldi 255` and `add`/`sub` it gives
  `not`, `and`, `or`, `xor` (a few instructions each). `sub` is there because a
  subtraction by `nand` and `add` is long, and `addi` because counting by constants is
  what loops do (`addi 255` is "minus one").
* **`jz` and `jnz`** test A directly, so there are no flags to keep, save or explain.
* **I/O by instruction** (`out`, `inp`, `led`), not memory-mapped: no address decoder,
  and the waiting is part of the instruction (the processor stalls), so programs need
  no polling loop.
* **`halt` keeps PC where it is.** The machine then repeats the `halt` for ever, which
  is the same as stopping, and needs no extra state.
* **One instruction per clock cycle** (unless it waits): no pipeline, no multi-cycle
  sequencer. At 12 MHz that is fast enough that the example programs need delay loops.
* **The program is in a ROM of multiplexers**, built from the assembled program when
  the design is elaborated (`romW` in `Cpu.wiz`). The HDL library has no memory
  primitive yet, so a block RAM cannot be asked for (FINDINGS.md, C1); the multiplexer
  chain costs one comparison per instruction, which yosys folds into LUTs. A program
  is therefore part of the bitstream: one design per program.

## The hardware

`coreStep` is one clock cycle of the core, as combinational logic (polymorphic in the
representation, as everything in this project):

* `decode`: control signals from the opcode alone (write A, ALU operation, operand from
  memory or the constant, write memory, write LEDs, the three jumps, `out`, `inp`,
  `halt`);
* the ALU: `A + b`, `A − b`, `¬(A ∧ b)` or `b`, where `b` is `M[a]` or `k`;
* the next PC: the target or PC + 1;
* `go`: the instruction completes this cycle (it is not `halt`, not `out` with the
  transmitter busy, not `inp` with no byte); only then does any register change.

`cpu n prog` adds the program ROM, the UART receiver (through the input synchroniser)
with its one-byte buffer, and the transmitter, all from `Uart.wiz` (`n` cycles per bit:
104 on the board). The core sees the UART as `Port` (transmitter ready, byte waiting,
the byte) and acts on it with `Act` (send, the byte, take the waiting byte).

## The architecture as a function

`Spec.exec s i p` is what instruction `i` does in state `s` given the UART's state `p`
(the table above, one line per instruction; `Instr` is an inductive type and
`Spec.decode` maps a word to it). `Spec.step prog : Arch → Arch` is the whole machine
as a pure step function, where `Arch` is the state plus an ideal serial line: the
bytes still to come and the bytes sent so far.

## What is proved

In `src/Icestick/Proofs/Cpu.wiz`, checked by the kernel on `grail build`:

* **The core is the architecture** (`Cpu.core_ok`): for every opcode (all sixteen),
  every operand, every state (PC, A, all of memory, LEDs: symbolic, not enumerated)
  and every state of the UART (transmitter ready or not, a byte waiting or not, any
  byte), one cycle of `coreStep` at values gives exactly the next state and the action
  of `Spec.exec` on the decoded instruction, a stall included.
* **The ROM holds the program** (`Cpu.rom_count`, …): for each example program, the
  instruction `fetch` reads at each of the 256 addresses is `Spec.fetch` of the
  assembled program (an exhaustive check, by evaluation).
* **Programs**: the countdown from k halts with A = 0 after 3k + 2 steps, for every k
  below 256 (`Cpu.countdown_all`); `hi` sends `hi\r\n` (`Cpu.hi_sends`); `echo+1`
  answers `a b c` with `b c d` (`Cpu.echo_abc`).

### How the proof works

Each case of `Cpu.core_ok` is `rfl`: the kernel evaluates both sides with the state
left symbolic, and they must come out as the same term. For a fixed opcode and fixed
UART flags, the decoder and every control signal evaluate to constants and their
multiplexers disappear. What is left are terms in the symbolic state, and they meet
only if both sides compute them the same way, so two things are written with care:

* the hardware uses the two data-dependent conditions, "A = 0" and "the address is
  `j`", only as multiplexer selects (`Hw.mux (eqLit s.acc 0) …`), never combined with
  other logic, and
* the architecture writes those two conditions with `Spec.pick` (the value instance's
  multiplexer) and `Spec.is`; the rest of `Spec.exec` is ordinary code over an
  inductive type of instructions, with whole-state results per instruction.

So the proof shows that the decoder, the ALU selection, the PC logic, the write
enables and the stall logic (`go`) implement the table; it does not show anything
about `BitVec.add` itself (both sides use it).

Not proved: that `cpu` as a whole (the UART, the buffer, the ROM wired to the core)
runs programs as `Spec.step` does. The ROM lemma and the core lemma are its two halves,
but are not glued into one statement about `cpu`'s runs; the simulation tests compare
the whole design with `Spec.step` on the example programs instead.

## The assembler

`Asm.assemble : List Asm → List Nat` (`src/Icestick/Asm.wiz`). A program is a list of
instructions and labels; jumps name labels:

```
def Prog.echo : List Asm :=
  .label "loop" :: .inp :: .addi 1 :: .out :: .led :: .jmp "loop" :: .nil
```

`Asm.problems` reports unknown or repeated labels, operands out of range and programs
over 256 instructions.

## The example programs

| program | what it does | instructions |
|---|---|---|
| `count` | counts on the LEDs, about four steps per second | 18 |
| `echo` | sends back each byte received plus one (`a` → `b`), shows it on the LEDs | 5 |
| `hi` | sends `hi\r\n` about ten times per second | 21 |
| `countdown k` | A = k, k − 1, …, 0, then halts | 5 |

## Trying it

```sh
grail build
grail test                         # tests/cpu.wiz among them
.grail/bin/icestick gen            # build/cpu_count.v, cpu_echo.v, cpu_hi.v (and the rest)
.grail/bin/icestick bit            # synthesis, place and route; see the logs in build/
.grail/bin/icestick flash cpu_hi
P=/dev/ttyUSB1; stty -F $P 115200 raw -echo cs8 -cstopb -parenb clocal min 0 time 10
timeout 2 cat $P                   # hi, hi, hi, …
.grail/bin/icestick flash cpu_echo
.grail/bin/icestick cpu-echo $P    # bytes in, bytes + 1 out
.grail/bin/icestick flash cpu_count  # and watch the LEDs
```
