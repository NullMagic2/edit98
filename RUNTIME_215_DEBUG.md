# Runtime error 215 debugging

The earlier 0.5.7 startup-error revision was compiled with Free Pascal 3.2.2
targeting i8086 MS-DOS in Large memory model, using the same project options (`-Tmsdos -WmLarge -Cp8086
-O1 -CX -XX -Xs -g-`).

The startup path was audited from generated i8086 assembly. Three operations
were hardened:

1. `ParamCount` and `ParamStr(1)` are evaluated before the resident mouse driver
   is executed. FPC's MS-DOS RTL initializes `argv` lazily; parsing the command
   line after a TSR returns can depend on DOS process state.
2. The hardware text cursor is hidden with a direct PC-98 `INT 18h / AH=12h`
   instruction rather than the generic `Registers`/`Intr` wrapper.
3. Caret timing now uses a bounded sub-minute counter (0..5999), with no checked
   32-bit multiplication.

The release build produces `EDIT98.EXE` directly.


## RTF import error in 0.6.3

The later RTF-specific error shown while the Open dialog was still visible points
to the import path rather than the startup fixes above. Version 0.6.4 disables
generated arithmetic-overflow checks only inside the manually bounded RTF codec,
keeps range checks enabled, and adds `RTFTEST.PAS` to isolate the decoder. This
change has not yet been compiled or target-tested in this environment.
