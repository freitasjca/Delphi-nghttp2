# Getting `libnghttp2` on Linux

`Delphi-nghttp2` loads `libnghttp2.so.14` at startup via `dlopen` — the
shared library must be on the dynamic linker's search path.

---

## Install from the system package manager (recommended)

### Debian / Ubuntu / Raspberry Pi OS

```bash
sudo apt install libnghttp2-14
```

> The `-dev` package (`libnghttp2-dev`) adds headers and the unversioned
> `.so` symlink — needed only if you are *building* nghttp2-based C code
> yourself. For running a Delphi-compiled binary, the `-14` runtime package
> is all you need.

Verify the installed version:

```bash
dpkg -l libnghttp2-14
```

### Fedora / RHEL / CentOS Stream

```bash
sudo dnf install libnghttp2
```

### Arch Linux

```bash
sudo pacman -S libnghttp2
```

### openSUSE

```bash
sudo zypper install libnghttp2-14
```

---

## Verify the library is loadable

```bash
ldconfig -p | grep nghttp2
```

Expected output:
```
libnghttp2.so.14 (libc6,x86-64) => /usr/lib/x86_64-linux-gnu/libnghttp2.so.14
```

If it doesn't appear, run `sudo ldconfig` after installation to update the
linker cache.

---

## Run without installing (LD_LIBRARY_PATH)

If you can't install system-wide (shared hosting, CI container, cross-compile
target), download the package and extract the `.so`:

```bash
apt-get download libnghttp2-14
dpkg -x libnghttp2-14_*.deb /tmp/nghttp2-extract
export LD_LIBRARY_PATH=/tmp/nghttp2-extract/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
```

Or build from source and install to a local prefix (see *Build from source*
below).

---

## Build from source

Use this when you need a version newer than what the distro ships, or for
cross-compilation targets.

**Prerequisites:** GCC or Clang, CMake ≥ 3.25, pkg-config.

```bash
git clone https://github.com/nghttp2/nghttp2.git
cd nghttp2

cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release  \
  -DENABLE_LIB_ONLY=ON        \
  -DENABLE_SHARED=ON          \
  -DENABLE_STATIC=OFF         \
  -DENABLE_EXAMPLES=OFF       \
  -DENABLE_APP=OFF            \
  -DENABLE_TESTS=OFF          \
  -DCMAKE_INSTALL_PREFIX=/usr/local

cmake --build build --target nghttp2
sudo cmake --install build
sudo ldconfig
```

Verify:

```bash
ldconfig -p | grep nghttp2
# → libnghttp2.so.14 => /usr/local/lib/libnghttp2.so.14
```

---

## ARM / cross-compile targets

The SONAME is `libnghttp2.so.14` on all Linux targets (x86_64, ARM64,
ARMv7). Install the ARM package on the target board:

```bash
sudo apt install libnghttp2-14        # Raspberry Pi OS / Ubuntu ARM
```

For Delphi Linux64 cross-compilation (PAServer on ARM): install on the
physical ARM board, deploy the binary from Windows via PAServer, and run on
the board — the loader finds the ARM system library automatically.

---

## Also needed: OpenSSL (TLS mode only)

`TTlsServerContext` / `TTlsClientContext` load `libssl.so.3` and
`libcrypto.so.3` (OpenSSL 3.x). These are almost always already installed
on modern Linux distributions.

```bash
sudo apt install libssl3          # Debian / Ubuntu
sudo dnf install openssl-libs     # Fedora / RHEL
```

Verify:

```bash
ldconfig -p | grep -E "libssl|libcrypto"
```

For h2c (cleartext) operation only `libnghttp2.so.14` is required.
