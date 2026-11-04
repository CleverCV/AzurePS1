# AzurePS1
### A PlayStation 1 (PSX) emulator created with love! (LÖVE2D)

**AzurePS1** is an experimental PlayStation 1 emulator written in **Lua**, powered by the **LÖVE2D framework**.

The goal of this project is to recreate the original PlayStation hardware through software emulation, allowing users to load their own BIOS and PlayStation game images.

---

## Features

- [x] LÖVE2D application framework
- [ ] MIPS R3000A CPU emulation
- [ ] PlayStation memory management
- [ ] External BIOS loading
- [ ] GPU emulation and rendering
- [ ] GTE (Geometry Transformation Engine)
- [ ] SPU (Sound Processing Unit)
- [ ] CD-ROM emulation
- [ ] Controller support
- [ ] ISO and BIN/CUE game loading
- [ ] Debugger and CPU inspection tools

## Built With

| Technology | Purpose |
|---|---|
| Lua | Main programming language |
| LÖVE2D | Graphics, audio and input |
| GLSL | GPU shaders |
| PowerShell | Development environment |

## Project Structure

```text
AzurePS1/
├── main.lua
├── conf.lua
├── README.md
├── env.ps1
│
├── core/
│   ├── cpu.lua
│   ├── memory.lua
│   ├── bios.lua
│   ├── gpu.lua
│   ├── gte.lua
│   ├── spu.lua
│   ├── cdrom.lua
│   ├── controller.lua
│   └── interrupts.lua
│
├── frontend/
│   ├── renderer.lua
│   ├── interface.lua
│   ├── debugger.lua
│   ├── audio.lua
│   └── input.lua
│
├── shaders/
│   ├── psx.glsl
│   ├── crt.glsl
│   └── texture.glsl
│
├── assets/
│   ├── fonts/
│   ├── icons/
│   └── textures/
│
├── bios/
├── games/
├── tests/
│
└── l2/
    └── love.exe
```

## Requirements

- Windows, Linux or macOS
- LÖVE2D
- LuaJIT (included with standard LÖVE2D builds)
- A ""legally"" obtained PlayStation 1 BIOS
- PlayStation game images

## Installation

1. Clone or download the repository.
2. Make sure LÖVE2D is available in the `l2/` directory.
3. Place your BIOS file inside `bios/`.
4. Place your game images inside `games/`.
5. Run the project.

### Windows (PowerShell)

```powershell
.\env.ps1
Run-AzurePS1
```

Alternatively:

```powershell
.\l2\love.exe .
```

## Emulation Architecture

AzurePS1 uses a hybrid rendering architecture:

- **CPU:** Software emulation of the MIPS R3000A processor.
- **GPU:** PSX graphics command processing with LÖVE2D Canvas and GLSL shaders.
- **GTE:** Geometry calculations and 3D transformations.
- **SPU:** PlayStation audio processing.
- **CD-ROM:** Disc image reading and sector access.

The project aims to reproduce the original hardware behavior as accurately as possible.

## Development Status

**AzurePS1 is currently under development.**

The full PlayStation 1 emulation target is a long-term goal. Individual hardware components will be implemented and tested progressively.

## Disclaimer

AzurePS1 is an independent, community-driven emulation project.

PlayStation is a trademark of Sony Interactive Entertainment. AzurePS1 is not affiliated with, endorsed by, or associated with Sony.

BIOS files and game images are not included. Users must provide their own legally obtained copies.

---

**Made with love, Lua and LÖVE2D.**

*AzurePS1 — Bringing the original PlayStation experience to a new generation.* 💙