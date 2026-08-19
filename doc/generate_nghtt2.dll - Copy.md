# Generate **`nghttp2.dll` for Windows**.


## Compile for x64  

### Recommended route: MSVC + CMake

For a normal Windows application, I'd use **MSVC rather than MinGW** unless the application itself was built with MinGW.

1. Install **Visual Studio 2026** or **Visual Studio 2026 Build Tools**

   * Workload: **Desktop development with C++**
   * Include the Windows SDK.

2. Install **CMake** and **Git**.

3. Clone nghttp2:

```bash
git clone https://github.com/nghttp2/nghttp2.git
cd nghttp2
```

4. Configure a 64-bit build:

```bash
cmake -S . -B build64 -G "Visual Studio 18 2026" -A x64
```

5. Build Release:

```bash
cmake --build build64 --config Release
```

6. Look under:

```text
build64\
```

for the generated `nghttp2.dll` (the exact output location can vary with the nghttp2 version/configuration).

### One important correction

You **don't need to start VS Code from the “x64 Native Tools Command Prompt”** when using:

```bash
cmake -G "Visual Studio 18 2026" -A x64
```

The Visual Studio generator knows how to create an x64 build. However, using the **Developer Command Prompt** can still be useful if you need MSVC environment variables available to other commands.

### Also important: don't mix MSVC and MinGW

If your target application is a normal Windows program compiled with Visual Studio/MSVC, build nghttp2 with **MSVC** too.

If your application expects a MinGW DLL, use the MinGW/MSYS2 route instead.

## Compile x86  
To compile **nghttp2 for 32-bit Windows (x86)** with **CMake + Visual Studio 2022**, use these commands.

### 1. Clone nghttp2

```bat
git clone https://github.com/nghttp2/nghttp2.git
cd nghttp2
```

### 2. Configure for x86

```bat
cmake -S . -B build32 -G "Visual Studio 18 2026" -A Win32
```

The important part is:

```text
-A Win32
```

That tells Visual Studio/CMake to build **32-bit x86**.

### 3. Compile Release

```bat
cmake --build build32 --config Release
```

### 4. Find the DLL

After compilation, look in:

```text
build32\Release\
```

or, depending on the nghttp2 CMake configuration:

```text
build32\lib\Release\
```

You should get the 32-bit `nghttp2.dll` along with the import library (`.lib`).

### For comparison

**64-bit:**

```bat
cmake -S . -B build64 -G "Visual Studio 18 2026" -A x64
cmake --build build64 --config Release
```

**32-bit x86:**

```bat
cmake -S . -B build32 -G "Visual Studio 18 2026" -A Win32
cmake --build build32 --config Release
```

So if your application is **32-bit**, use `Win32`; if it's **64-bit**, use `x64`.

If you want, I can also give you the **exact CMake commands to build only the nghttp2 DLL (without the examples/tests)**.


## Compile only dll  

For **nghttp2 + Visual Studio 18 2026 + 32-bit x86**, you can configure CMake to disable examples and tests and then build the library.

### x86 / 32-bit — DLL only

From the root of the `nghttp2` source directory:

```bat
cmake -S . -B build32 -G "Visual Studio 18 2026" -A Win32 ^
  -DENABLE_LIB_ONLY=ON ^
  -DENABLE_EXAMPLES=OFF ^
  -DENABLE_APP=OFF ^
  -DENABLE_HPACK_TOOLS=OFF ^
  -DENABLE_TESTS=OFF ^
  -DENABLE_FAILMALLOC=OFF ^
  -DENABLE_ASIO_LIB=OFF
```

Then compile:

```bat
cmake --build build32 --config Release --target nghttp2
```

### Find the DLL

After a successful build, search:

```bat
dir /s /b build32\nghttp2.dll
```

That will give you the **exact location** of the generated DLL.

You can also find the import library:

```bat
dir /s /b build32\nghttp2.lib
```

### If you want 64-bit instead

Use exactly the same configuration, changing `Win32` to `x64` and `build32` to `build64`:

```bat
cmake -S . -B build64 -G "Visual Studio 18 2026" -A x64 ^
  -DENABLE_LIB_ONLY=ON ^
  -DENABLE_EXAMPLES=OFF ^
  -DENABLE_APP=OFF ^
  -DENABLE_HPACK_TOOLS=OFF ^
  -DENABLE_TESTS=OFF ^
  -DENABLE_FAILMALLOC=OFF ^
  -DENABLE_ASIO_LIB=OFF

cmake --build build64 --config Release --target nghttp2
```

**Important:** `nghttp2.dll` must have the **same architecture as the program loading it**. A 32-bit application needs the x86 DLL; a 64-bit application needs the x64 DLL.


## Requirements  

- Install **Visual Studio Community is free for individual developers**   
- Install CMake 


### Install **CMake**  
  

Install standalone CMake (recommended)

Install CMake from the official installer:

[CMake Downloads](https://cmake.org/download/?utm_source=chatgpt.com)  

Windows x64 Installer:

```bat
cmake-4.x.x-windows-x86_64.msi
```

During installation, select:

**Add CMake to the system PATH**

Then restart VS Code and check:

```powershell
cmake --version
```

### Install **Visual Studio Community is free for individual developers**    




For your specific goal—**compiling `nghttp2.dll` 64-bit on Windows**—I recommend installing **Visual Studio Community** rather than the Build Tools. It gives you the compiler plus an IDE, and you can still use VS Code for your actual work.

### 1. Download Visual Studio

Use Microsoft's official download page:

[Download Visual Studio Community](https://visualstudio.microsoft.com/downloads/?utm_source=chatgpt.com)

Choose **Visual Studio Community** → **Free download**. ([Visual Studio][2])

### 2. During installation, select C++

When the Visual Studio Installer opens, look for **Workloads**.

Select:

**Desktop development with C++**

This is the important part. It installs the MSVC compiler and Windows development tools needed to build nghttp2.

You don't need to install every optional component.

### 3. Install

Click **Install**.

It may take some time because the C++ development tools are fairly large.

### 4. After installation

You can continue using **VS Code**.

You'll have:

* VS Code → where you edit/work with the nghttp2 source
* Visual Studio/MSVC → provides the C++ compiler
* CMake → generates the build
* Git → downloads nghttp2

Then we can build it with:

```bat
git clone https://github.com/nghttp2/nghttp2.git
cd nghttp2

cmake -S . -B build64 -G "Visual Studio 18 2026" -A x64

cmake --build build64 --config Release
```

**One correction to my previous answer:** Microsoft now has newer Visual Studio releases available, while **Visual Studio 2022 is still available from Microsoft's older-downloads page**. ([Visual Studio][3]) If you specifically want the VS 2022 toolchain because of compatibility with your application, use the 2022 version.

If you tell me whether you're on **Windows 10 or Windows 11**, I can walk you through the installation **screen by screen**, including exactly which boxes to tick for compiling nghttp2.

[1]: https://visualstudio.microsoft.com/vs/community/?WT.mc_id=IoT-MVP-5002324%5C&utm_source=chatgpt.com "Free IDE and Developer Tools - Visual Studio Community"
[2]: https://visualstudio.microsoft.com/downloads/?utm_source=chatgpt.com "Visual Studio Downloads for Windows"
[3]: https://visualstudio.microsoft.com/vs/older-downloads/?utm_source=chatgpt.com "Visual Studio Older Downloads - 2022, 2019, 2017 and older"

