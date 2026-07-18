# edit98
## A powerful and lightweight visual editor for PC98
EDIT98 is an easy-to-use text and document editor designed specifically for PC-98 MS-DOS. Inspired by the simplicity of classic DOS editors, it combines a familiar menu-driven interface with features that make it practical for more than just editing plain text.

<img width="1202" height="756" alt="image" src="https://github.com/user-attachments/assets/d246e6a4-733e-4be2-8799-7cfa748a4e32" />


## Easy, but fairly powerful
EDIT98 supports: 

* Mouse and keyboard support, including for copying and pasting
* Configurable page layouts, including custom paper formats, margins, and portrait or landscape orientation
* Partial RTF support for working with formatted documents
* Integrated printing system allows documents to be prepared and printed directly from the editor, without requiring a separate word-processing application.

## Built for the PC-98, not merely ported to it

The PC-98 has its own display architecture, keyboard environment, mouse conventions, character handling, and printing ecosystem. EDIT98 is developed with those characteristics in mind, including support for PC-98 mouse operation and PC-PR201-compatible printing, instead of assuming the behavior of an IBM PC-compatible machine.

<img width="1204" height="722" alt="image" src="https://github.com/user-attachments/assets/9a178b77-674d-4e40-aeeb-98362aa5877b" />


Rather than treating the PC-98 as just another target for a generic DOS application, the editor is intended to feel at home on the platform and to work with the conventions and capabilities of the Japanese PC-98 ecosystem.

The result is an application that feels like software that could genuinely belong on a PC-98 system: lightweight enough for DOS, familiar in operation, but equipped with conveniences that make the machine more practical for everyday document editing.


## Before Running EDIT98

EDIT98 uses PC-98 mouse and printer services that may not be enabled automatically by MS-DOS or by your emulator. For the full experience, make sure both mouse and printing support are available before starting the editor.

## Enable mouse support

EDIT98 supports mouse-driven menus and interface controls, but a compatible DOS mouse driver must be loaded first.

If your system includes MOUSE.COM, run:

> MOUSE.COM

before launching EDIT98.

You can then start the editor normally:

> EDIT98.EXE

For convenience, you may also add the mouse driver to your startup configuration or use a batch file that loads MOUSE.COM before starting EDIT98.

If the mouse pointer does not appear or does not respond, verify that:

* Mouse support is enabled in your PC-98 emulator.
* A compatible DOS mouse driver such as MOUSE.COM has been loaded.
* The emulator is correctly capturing or forwarding mouse input to the emulated PC-98 system.

## Enable printing support

EDIT98 includes integrated printing designed around the PC-PR201-compatible printer interface. Printing therefore requires printer support to be enabled and configured in your PC-98 environment or emulator.

When using an emulator such as Neko Project II/W, make sure its printer functionality is enabled and that printer output is connected to an appropriate destination, such as a virtual printer, output file, or Windows printing backend, depending on your emulator configuration.

EDIT98 handles document layout internally, including:

* Paper size
* Custom paper dimensions
* Margins
* Portrait and landscape orientation
* Pagination


<img width="1198" height="770" alt="image" src="https://github.com/user-attachments/assets/51b6eff4-65db-48a4-9a72-31042831f9d4" />



The resulting output is then sent through the emulated PC-98 printer interface.

If printing produces no output, check that the emulator's printer device is enabled and configured before launching EDIT98.

* Edit98: a simple text editor when you need one. A surprisingly capable document editor when you need more. *
