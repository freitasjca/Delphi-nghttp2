# Getting `nghttp2.dll` on Windows

`Delphi-nghttp2` loads `nghttp2.dll` at startup via `SafeLoadLibrary` — the
DLL must be findable by Windows's standard loader search order (`.exe`
directory first, then `PATH`).

Three options, from easiest to most involved:

---

## Option A — Prebuilt from curl for Windows (recommended)

No compiler or toolchain needed. The [curl for Windows](https://curl.se/windows/)
project bundles `nghttp2.dll` alongside `curl.exe`.

1. Go to **https://curl.se/windows/**

2. Download the package that matches your Delphi target platform:

   | Delphi target | Package to download |
   |---|---|
   | Win64 (`dcc64`, Project → Target platforms → Windows 64-bit) | **Win64** package |
   | Win32 (`dcc32`, Project → Target platforms → Windows 32-bit) | **Win32** package |

   The filename looks like `curl-X.YY.Z_A-winNN-mingw.zip`.

3. Extract the zip and open the `bin\` subfolder.

4. Copy `nghttp2.dll` next to your compiled `.exe`.

> **Bitness must match.** A Win64 executable loading a Win32 DLL (or vice
> versa) fails immediately with error `0xc000007b`. Verify with:
> ```bat
> dumpbin /headers nghttp2.dll | findstr machine
> ```
> `14C` = Win32 (x86) · `8664` = Win64 (x64)

---

## Option B — vcpkg

Requires [vcpkg](https://vcpkg.io/) bootstrapped and the
**Desktop development with C++** workload installed in Visual Studio or the
Visual Studio Build Tools.

```bat
vcpkg install nghttp2:x64-windows   :: Win64 (most common)
vcpkg install nghttp2:x86-windows   :: Win32
```

The DLL lands in `<vcpkg-root>\installed\<triplet>\bin\nghttp2.dll`.
Copy it next to your `.exe`, or add that `bin\` folder to `PATH`.

---

## Option C — Build from source (MSVC + CMake)

Use this if you need a specific version, debug symbols, or the import library
(`.lib`).

**Prerequisites:** Visual Studio with the
**Desktop development with C++** workload, CMake ≥ 3.25, Git.

> **Visual Studio Community** is free for individual developers:
> [https://visualstudio.microsoft.com/downloads/](https://visualstudio.microsoft.com/downloads/)
> During installation select the **Desktop development with C++** workload.
> CMake: [https://cmake.org/download/](https://cmake.org/download/) — tick
> "Add CMake to the system PATH" during install.

### Win64

```bat
git clone https://github.com/nghttp2/nghttp2.git
cd nghttp2

cmake -S . -B build64 -G "Visual Studio 17 2022" -A x64 ^
  -DENABLE_LIB_ONLY=ON  ^
  -DENABLE_SHARED=ON    ^
  -DENABLE_STATIC=OFF   ^
  -DENABLE_EXAMPLES=OFF ^
  -DENABLE_APP=OFF      ^
  -DENABLE_TESTS=OFF

cmake --build build64 --config Release --target nghttp2
```

Find the output:
```bat
dir /s /b build64\nghttp2.dll
```

### Win32 (32-bit)

```bat
cmake -S . -B build32 -G "Visual Studio 17 2022" -A Win32 ^
  -DENABLE_LIB_ONLY=ON  ^
  -DENABLE_SHARED=ON    ^
  -DENABLE_STATIC=OFF   ^
  -DENABLE_EXAMPLES=OFF ^
  -DENABLE_APP=OFF      ^
  -DENABLE_TESTS=OFF

cmake --build build32 --config Release --target nghttp2
dir /s /b build32\nghttp2.dll
```

> **Visual Studio version:** replace `"Visual Studio 17 2022"` with the
> generator matching your installed toolchain (`"Visual Studio 16 2019"`,
> `"Visual Studio 15 2017"`, …). Run `cmake --help` for the full list.

---

## Where to place the DLL

| Scenario | Placement |
|---|---|
| Run from Delphi IDE (F9) | Same folder as the `.exe` output (usually `Win32\Debug\` or `Win64\Release\`) |
| Deployed `.exe` | Same folder as the `.exe` |
| Multiple `.exe`s sharing one copy | Any folder on the system or user `PATH` |

The `.exe` directory is always searched first — no registry or `PATH` change
required.

---

## Verify the DLL loads

```pascal
if not NghttpLoad then
  raise Exception.Create(NghttpLoadError);
// or just call TNghttp2Server.Start — it calls NghttpLoad automatically
```

`NghttpLoadError` returns the DLL names tried and the OS error, so the
message tells you exactly what went wrong.

---

## Also needed: OpenSSL DLLs (TLS mode only)

`TTlsServerContext` / `TTlsClientContext` load `libssl-3-x64.dll` and
`libcrypto-3-x64.dll` (OpenSSL 3.x) or their 1.1.x equivalents. Place those
next to the `.exe` as well.

Prebuilt OpenSSL binaries for Windows:
- [https://slproweb.com/products/Win32OpenSSL.html](https://slproweb.com/products/Win32OpenSSL.html) (full installer)
- The same curl for Windows bundle — `bin\libssl-3-x64.dll` and `bin\libcrypto-3-x64.dll` are included in the Win64 package alongside `nghttp2.dll`.

For h2c (cleartext) operation only `nghttp2.dll` is required.
