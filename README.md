Hubris is programming language, consisting of a very thin layer atop 65C02 assembly language. It is designed to target the (fictional) Eiling Technologies ARS, but can probably be coerced into targeting any sane 65C02 system. It uses the excellent WLA-DX assembler and linker as the backend.

This documentation is more for my own reference than any other purpose. I don't really expect other people to end up in the situation of needing a language like Hubris. Technically, all the answers needed are in this document, but they're not easy to find if you don't already know what to look for. If you have a question whose answer is not obvious here, the best way to get an answer is to contact me on IRC. I go by SolraBizna on irc.tejat.net.

# Goals

Hubris has three major goals:

- Efficiently allocating local variables, parameters, etc. in a full-system program
- Improving the safety and efficiency of subroutine calls
- Reducing programmer workload for bank-switching

# Installation

(Note: `hcc.lua` is **NOT** the Hubris compiler. It is the Hubris compiler *compiler*. It is used to assemble `hubris.lua` from the components in `src`.)

Install Lua 5.3, LuaFileSystem, and LPEG. The latter two can be installed with LuaRocks:

    luarocks install luafilesystem
    luarocks install lpeg

On UNIX, you may want to put a symlink to `hubris.lua` somewhere in your PATH.

Hubris currently requires a recent build of WLA-DX, more recent than the official 9.5 release. The source can be found [here](https://github.com/vhelin/wla-dx).

# Usage

When you run the Hubris compiler, you provide it one or more source directories. The Hubris compiler recursively searches these directories and processes all `.65c` and `.hu` files it finds. `.hu` files are Hubris-language source files, and are fully processed. `.65c` files are raw 65C02 source files, and are passed on to the assembler with no further processing. (`.65c` files contain startup code, certain kinds of glue, and pure data.)

There is no file dependency or order dependency in `.hu` files. `#routine`s must each be fully contained inside one file, but other than that, the final compiled code is the same as if all `.hu` files are concatentated together before compiling (except in the case of `#alias`).

Hubris puts all its intermediate files, and `.o` files, into the output directory provided. By convention, this directory is named `obj`. In addition to the generated `.65c` and `.o` files, Hubris will place two important files in this directory:

- `common`: Should be included by every `.65c` file. Contains Hubris's beliefs about the memory map of the machine, `.DEFINE` directives for the assignments of the `#group`s and `#slot`s, and everything inside `#common`/`#endcommon` pairs.
- `link`: Pass this to `wlalink` to link the program as known by Hubris. If you want to add object files, an image file header, etc. then you should edit this file after running the Hubris compiler.

An example compile process:

    $ hubris.lua obj src
    $ wlalink -S -v obj/link MyGame.etars/main.rom

(You should really put this into a shell script or batch file rather than doing this manually each time. Using a Makefile would be even better.)

`.hu` files mainly contain Routines. A Routine is a block of code, and has its own scope for local variables and parameters. Recursion, directly or indirectly, is normally not allowed; that is, a Routine may not normally cause *itself* to be called again before the first call returns, directly or indirectly. This lack of recursion is what makes Hubris's variable allocation system work.

Entry Points are a special kind of routine. Entry Points are not called from other Routines. Instead, they are jumped into via interrupt vectors, or called from special assembly glue code. An Entry Point, along with every Routine called directly or indirectly by that Entry Point, forms a Subprogram. Routines from one Subprogram cannot call routines from another; otherwise, interrupt safety is at risk.

Subprograms separate routines that must be able to interrupt one another safely. A typical ARS game will have three or four Entry Points, and therefore three or four Subprograms:

- `IRQ` will contain some very slim graphics code that does scanline effects.
- `BRK` will contain a short routine to gracefully halt execution if a `BRK` is encountered. (The standard ET init code handles BRKs, so if you're using that, you won't need a `BRK` subprogram.)
- `NMI` will contain code to do per-frame PPU updates, and audio code.
- `Main` will contain the vast bulk of the program, including all game logic.

Hubris does not assign any special meaning to any particular entry point name. You are free to define as many or as few as you like, with whatever names you like. You *must* define at least one, however; Routines that are not called from any Entry Point (dead Routines) are not included in the final program.

# Syntax

Hubris source files use `;` as a comment character, just like regular 65C02 assembly files. Each non-blank line is either:

- A Hubris directive, beginning with `#` (optionally preceded by whitespace)
- A line of 65C02 assembly, or WLA-DX directive (only allowed within a `#routine` or `#common`)

By convention, most Hubris directives are unindented, Hubris directives that "are code" (e.g. `#call` and `#return`) are indented to the same level as the surrounding 65C02 code (with a single tab).

## Include

    #include "relative/path/to/file.inc"

Use `#include` instead of `.INCLUDE`. Each source directory is searched in the order given on the command line. Please, please do not use a `.hu` extension for files meant to be included by other files; if you do, those files will be processed as independent source files. And please, regardless of what operating system you run Hubris on, please use `/` as a path component separator.

Hubris's variable and routine systems are relatively smart, so `#include` is mainly only needed for incorporating automatically-generated data files.

## Memory directives

Every Hubris program must contain, somewhere in its source, a `#bs` directive, a `#bankcount` directive, and at least one `#region` directive. These should generally be in their own source file, possibly named something like `memory.hu`.

    #bs <BS>

Informs Hubris of the hardwired BSx pin values for this cartridge. In the name of sanity, Hubris uses this information to determine both the slot count and the slot size. `<BS>`=0 means 1x32KiB slot, 1 means 2x16KiB slots, 2 means 4x8KiB slots, and 3 means 8x4KiB slots.

    #bankcount <count>

Informs Hubris of the number of ROM banks available for use. This must be a power of two.

    #region <first> <last> <name>

Informs Hubris of a region of memory that can contain variables. An ARS program will almost always have:

    #region $0000 $00FF fast
    #region $0250 $7FFF slow

Variables with hardcoded addresses may exist outside of these regions. In fact, if you hardcode every address, you don't need `#region` at all. (But then you've lost out on half the point of using Hubris...)

## Banks and Slots

If you are making a one-bank ROM, you can ignore this section.

WLA-DX has support for multiple banks and slots that is normally quite adequate. However, Hubris generates each `#routine` in a separate WLA `.SECTION`, and WLA-DX does *not* have support for ensuring that multiple `.SECTION`s will end up in the same bank. Since WLA-DX decides banks at link time, it also can not provide a way to optimize out longcalls and such. For these reasons, Hubris requires manual bank assignment. It has some features intended to make this a little easier.

    #group <n> <slot> <name>

Defines a group with the given name. A group is a logical collection of related routines and data that should always be mapped at the same time. Multiple groups may coexist in the same ROM bank, even if they occupy different slots. `n` is the 0-based index of the ROM bank this group will reside in. `slot` is the 0-based index *or* `#slot` name of the *slot* this group will occupy. Example:

    #group 0 VectorSlot InterruptCode
    #group 0 0 StartupCode
    #group 0 0 GameCode

Creates a group named `InterruptCode` which will occupy the `VectorSlot` slot, and groups named `StartupCode` and `GameCode` which will occupy the lowest slot. The groups, despite potentially occupying different slots, will coexist in the same ROM bank of the cartridge. (If this cartridge has `#bs 1` and `#slot 1 VectorSlot`, then `InterruptCode` will link to `$C000` and on, while `StartupCode` will link to `$8000` and on.)

Eventually, if `GameCode` grew large enough to need its own bank, WLA would start refusing to link this program. At that point, the directives could be changed to:

    #group 0 VectorSlot InterruptCode
    #group 0 0 StartupCode
    #group 1 0 GameCode

Bank switching logic would also need to be added to the program at this point.

    #slot <n> <name>

Defines a slot alias. It is not an error to have multiple different aliases for the same slot, but it is an error to have multiple aliases with the same name.

Example:

    #slot 0 LiveSlot
    #slot 1 FixedSlot
    #slot 1 InterruptSlot

`LiveSlot` might be the slot where game logic and data are found, and get switched out willy nilly. `FixedSlot` might be where some useful utilities (decompression and math routines, for instance) are always mapped. `InterruptSlot` might be the slot where the interrupt handlers are. Note that `FixedSlot` and `InterruptSlot` are both aliases to slot 1 in this example. If the game later changed to a four-slot memory map, `FixedSlot` and `InterruptSlot` could end up being mapped to different slots without requiring extra effort.

### Special Symbols

Hubris defines the following special symbols in the memory map file:

    hubris_Group_<name>_bank

The ROM bank number assigned to the given group.

    hubris_Group_<name>_slot

The slot number used by the given group.

    hubris_Slot_<name>_slot

The slot number for the given slot alias.

These are useful if you want to include mass amounts of data in the program, such as with the following `.65c` file:

    .INCLUDE "obj/common"
    
    ; The map data itself can live in whatever bank
    .SLOT hubris_Slot_DataSlot_slot
    .ORG 0
    .SECTION "map1" SUPERFREE
    map1:
    .INCLUDE "src/gen/map1.inc"
    .ENDS
    .ORG 0
    .SECTION "map2" SUPERFREE
    map2:
    .INCLUDE "src/gen/map2.inc"
    .ENDS
    
    ; The pointers to the map data live in the same bank as MainGroup
    .BANK hubris_Group_MainGroup_bank SLOT hubris_Slot_MainSlot_slot
    .ORG 0
    .SECTION "map_pointers" FREE
    map_banks:
    .DB :map1, :map2
    map_lows:
    .DB <map1, <map2
    map_highs:
    .DB >map1, >map2
    .ENDS

## Routines

    #routine <name> <...>
    ; assembly, such as look-up tables and "backward jumps", may go here
    #begin
    ; execution of the routine begins at this point
    #return
    ; more optional assembly, including possible "forward jump points"
    #endroutine

This is the structure of a Routine. Between `#routine` and `#endroutine` is the only place assembly lines are allowed. When someone does `#call <name>` (or glue assembly does `JSR <name>`/`JMP <name>`), execution begins at the location specified by `#begin`. `#return` is the equivalent of `RTS`. `#return INTERRUPT` will do `RTI` instead of `RTS`.

Routine names may not begin with `_`, but may otherwise be any valid identifier. A Routine name may also consist of arbitrarily many names separated by double colons (`::`), in which case this is a Subroutine. For example, `X::Y` is a subroutine of `X`. It has access to `#param` and `#sublocal` variables of `X`, and should only be called from `X` and other subroutines of `X`. Hubris exports a symbol whose name is the exact routine name, including any colons.

Every line within a `#routine` that is not a Hubris directive is passed to the assembler. They can contain instructions, labels, even WLA-DX directives. (Some WLA-DX directives, such as `.SECTION`/`.ENDS`, are inadvisable within a `#routine`.) Any labels defined within a `#routine` *should* begin with an `@` or be a +/- label, but if it doesn't, Hubris assumes you know what you're doing.

There may be more than one `#return`, in case the routine has multiple termination points. There may even be no `#return`, in case the routine is a deliberate infinite loop or otherwise never terminates, in which event `#endroutine` must be replaced with `#endroutine NORETURN` to indicate that this is intended.

Extra parameters to `#routine`:

- `ENTRY`  
  Marks this routine as an Entry Point. (Generally there will be very few of these in a program.)
- `CLOBBER <regs>`/`PRESERVE <regs>`
  `<regs>` is a list of registers, containing any of `A`, `X`, `Y`. `CLOBBER` indicates that this routine **intentionally clobbers** these registers. `PRESERVE` asks Hubris to push these registers on entry and pop them on `#return` or `#call ... JUMP`, marking them as callee-save registers. If a register is not listed as either `CLOBBER` or `PRESERVE`, it is **assumed** that this routine **does not alter** the register, either because it doesn't use it or because it has its own internal preservation logic. The caller can mark their `#call` with `PRESERVE` to indicate that they expect certain registers to be preserved, and Hubris will add pushes around the call only if required.
- `ORGA <value>`  
  Forces this routine to start at the given CPU address. (This applies to the first line of the routine, not necessarily to its `#begin`!) WLA will complain if the address is outside the relevant slot.
- `GROUP <name>`  
  This specifies which group the routine belongs to. Related routines should be put into the same group. It is an error to leave off the `GROUP` parameter for an `ENTRY` routine if multiple banks are available. (Non-`ENTRY` routines default to inheriting the `GROUP` of their nearest parent routine.)

## Calls

    #call <name> <...>

Calls a routine with the given name. This should be used instead of `JSR`/`JMP`, since otherwise Hubris won't know about the call, and won't be able to check / ensure register preservation.

Extra parameters to `#call`:

- `CLOBBER <regs>`/`PRESERVE <regs>`
  `<regs>` is a list of registers, containing any of `A`, `X`, `Y`. `CLOBBER` indicates that you don't care if the listed registers are clobbered, which is also the default state. `PRESERVE` indicates that you want the listed registers to be preserved. (Hubris will automatically add pushes and pops to ensure this, if and *only* if it is necessary.)
- `JUMP`  
  Use `JMP` instead of `JSR` to call this routine. Registers `PRESERVE` marked preserve in this routine (not in this `#call`) will be popped, as if this were a return. Saves a few cycles for explicit tail returns, and is the only condoned way of doing recursion. (`CLOBBER` and `PRESERVE` are meaningless and ignored with a `JUMP` call; registers are restored according to the calling routine's `PRESERVE` tags instead. This can cause problems if the routine being `JUMP`ed to has more destructive `CLOBBERS` than this routine. A future version of Hubris will raise an error if this happens.)
- `INTER`  
  This `#call` is intended for a different group. This tag *must* be present on calls across group boundaries, and *must not* be present on calls within the same group. Intergroup calls may incur a Longcall, see below.  
  Longcalls will clobber the accumulator; with the `-i` option, the compiler will clobber the accumulator on *all* `INTER` calls, even non-long ones; this helps head off accumulator-related accidents when groups are shuffled around.
- `UNSAFE`  
  Don't use this! This ignores the call for purposes of recursion checking, cross-subprogram call prevention, and variable allocation! This allows you to bypass all of Hubris's safety checks! This is a very naughty tag that you should only use if you know what you're doing! Before you do something like this, consider not doing the unsafe thing in the first place!

If you have a routine named `foo` and a parameter named `p_Bar`, you can access it within any routine that directly calls `foo` by writing `foo::p_Bar`. You should write any parameters immediately before the call, and read any return values immediately afterward.

### Longcall

When calling between groups that occupy the *same slot*, but *different ROM banks*, a Longcall is required. Hubris generates the following code:

            LDA #<TARGET
            STA ENTRY::glue_longcallSLOT::target
            LDA #>TARGET
            STA ENTRY::glue_longcallSLOT::target+1
            LDA #BANK
            STA ENTRY::glue_longcallSLOT::target_bank
            JSR ENTRY::glue_longcallSLOT

where TARGET, BANK, and SLOT are the target routine and the ROM bank and slot occupied by the target routine, and ENTRY is the entry point in effect.

You must implement your own `glue_longcallSLOT` routines according to your own use of slots. For example, if your code follows the convention that slot 0 contains all main routines, and `FixedUtilGroup` is in another slot is always mapped, you might provide:

    #routine Main::glue_longcall0 GROUP FixedUtilGroup CLOBBER A, X, Y
    #param fast PTR target
    #param fast BYTE target_bank
            #begin
            ; Save the current slot 0 mapping
            LDA r_BankSelect
            PHA
            ; Push the return address, as if by JSR
            LDA #>(_tail-1)
            PHA
            LDA #<(_tail-1)
            PHA
            ; Activate the target bank in slot 0
            LDA target_bank
            STA r_BankSelect
            ; Indirect JMP! (There is no indirect JSR, so we explicitly pushed
            ; the return address and did this instead.)
            JMP (target)
            ; restore slot 0 mapping, clobbering Y rather than A
            ; (According to our program's convention, A may contain a return
            ; value, while Y may not. Therefore, we clobber Y here.)
    _tail:  PLY
            STY r_BankSelect
            #return
    #endroutine

As you can see, long calls will have a significant amount of overhead compared to regular ones. This is why you should keep related code in the same bank, if not the same `GROUP`, whenever possible.

(The call to the `longcall` glue bypasses recursion checks and certain other housekeeping, so you must be careful what you write inside. For one thing, you should only provide `#params`. If you are having trouble understanding these principles, you should consider just using the above code verbatim.)

## Indirect Callers

    #indirectcaller <routine>
    #indirectcallers <routine>, <routine>, ...

When placed within a Routine, indicates that that routine will be called through a function pointer, by the given routines. Hubris behaves as though the listed routines contain a `#call` to this routine, but doesn't actually generate any calling code.

This is an advanced directive. If you don't know why you need it, you don't need it. (But if you do need it, there's no other way to accomplish it without generating spurious code.)

## Variables

A variable declaration looks like:

    #<type> <location> <size> <name> <...>

There are four types of variable in Hubris:

- `#global`: Not scoped, and potentially shared between subprograms. Also used, with hardcoded addresses, to denote hardware registers.
- `#local`: Accessible only from the active scope.
- `#sublocal`: Accessible from the active scope and from the scopes of Subroutines of the active `#routine`. (All Routines are, at least, Subroutines of their Entry Point.)
- `#param`: Accessible from the active scope, and the scopes of *callers* of this `#routine` (using `routine::variable` notation).

Location may be:

- The exact address the variable must be located at (interpreted as hex if a leading `$` is present, and as decimal otherwise)
- The name of a `#region` in which the variable should be allocated
- `ANY`, indicating that the variable may be placed in the first `#region` that has room for it (after all pickier variables have been placed)

Size may be:

- `<n>`: `<n>` contiguous bytes are required for the variable.
- `<n>/<m>`: `<n>` one-byte slots, each separated by `<m>` bytes of unused space, are required for this variable. (Useful for funky indexing tricks.)
- `<n>*<l>`: `<n>` `<l>`-byte slots are required for this variable.
- `<n>*<l>/<m>`: `<n>` `<l>`-byte slots, each separated by `<m>` bytes of unused space, are required for this variable. (Useful for even more funky indexing tricks.)
- `BYTE`, `WORD`, and `PTR`: Syntactic sugar for `1`, `2`, and `2`, respectively.

(The size value is used only when placing the variables; Hubris has no choice but to take it on faith that your code accesses the variables in a manner consistent with their sizes.)

Extra parameters:

- `PERSIST`: Like declaring a `static` local variable in C. The variable's lifetime is the entire program, rather than a single call to its containing scope. (This is redundant for `#global`s.) A `PERSIST` variable may not share a memory location with any other variable, so use these sparingly.

## Flags

    #<type>flag <name> <...>

Declares an atomic boolean Flag. Flags are implemented using the Rockwell `SMBx`/`RMBx`/`BBSx`/`BBRx` instructions. They will always live in the "lowest" `#region`; therefore, if Flags are used, the "lowest" `#region` must be contained entirely in the zero page.

Types, scoping rules, and extra parameters are the same as for variable declarations. Be aware that a memory byte that is used for Flags will not be used for any other purpose; one function with 2048 local Flags will prevent any non-Flag use of the zero page!

    #branchflagset <name> <label>
    #branchflagclear <name> <label>
    #branchflagreset <name> <label>

Corresponds to the `BBSx`/`BBRx` instructions. Atomically tests the Flag and branches to `<label>` if it is currently set (`#branchflagset`) or clear (`#branchflagclear`/`#branchflagreset`).

    #setflag <name>
    #clearflag <name>
    #resetflag <name>

Corresponds to the `SMBx`/`RMBx` instructions. Atomically sets (`#setflag`) or clears (`#clearflag`/`#resetflag`) the Flag.

## Aliases

    #alias <aliasname> <contents>
    #globalalias <aliasname> <contents>

Anywhere in assembly source code `<aliasname>` is found, `<contents>` is processed instead. `<contents>` will be processed as if it had been written instead of `<aliasname>` at that point in the source, including possibly being handled as an alias. (Hubris makes no attempt to detect alias loops; processing such a loop will hang the compiler.)

Aliases may be used to provide synonyms for variables, enabling some rudimentary polymorphism. They may also be used to create constants.

Unlike every other part of Hubris, `#alias` have source file scope. An `#alias` is effective only on lines after it is defined, and then only until a corresponding `#unalias`. `#globalalias`, on the other hand, is global and cross-file in scope, including lines before the `#globalias` directive.

Aliases are only processed in assembly source, such as in `#routine`s and `#common`s. Aliases do not take effect in Hubris directives. `#globalalias` processing is performed after all `#alias` processing.

    #unalias <aliasname>

Forgets a previously-defined alias. There is no equivalent directive for global aliases.

## Exports

    #export <name> [<exportedname>]

**NOT IMPLEMENTED YET**

`<name>` is a variable active in the current scope. A symbol for this variable will be exported to assembly code. If `<exportedname>` is provided that will be the symbol name, otherwise the variable's name is used.

## Commons

    #common
    ; WLA directives may go here
    #endcommon

This directive is used to add directives to the `obj/common` file generated by Hubris. Directives here will be effective in every routine and assembly file. (Don't put `.SECTION` directives and the like in here unless you're really sure you know what you're doing.)

For example, if you want to use the W65C02 `WAI`/`STP` instructions (which WLA doesn't know about), you might have the following `#common` tucked away in one of your source files:

    #common
    .MACRO WAI
    .DB $CB
    .ENDM
    .MACRO STP
    .DB $DB
    .ENDM
    #endcommon

And then every `#routine` or assembly file could use `WAI` and `STP` like normal instructions.
