@echo off
rem Build with the Free Pascal i8086 -> MS-DOS cross-compiler.
rem The Large memory model resembles Turbo Pascal's normal DOS model.
ppcross8086 -Tmsdos -WmLarge -Cp8086 -O1 -CX -XX -Xs -g- edit98.pas
