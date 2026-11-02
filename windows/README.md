# OrcaSlicer Nonplanar for Windows

Windows x64 port of [fich-l/orcaslicer-nonplanar](https://github.com/fich-l/orcaslicer-nonplanar)
(OrcaSlicer 2.4.2, nonplanar v0.1). The original patch is used unchanged.
`orca-nonplanar-windows.patch` is applied on top of it.

Put these files into a clone of that repository, keeping their folders:

```
.github/workflows/build-windows.yml
windows/build-windows.ps1
windows/orca-nonplanar-windows.patch
windows/README.md
```

## Option 1: build on GitHub (nothing to install)

1. Fork `fich-l/orcaslicer-nonplanar` on GitHub. Keep the fork public: public
   repositories get free Actions minutes and faster runners.
2. Add the files to your fork:

   ```powershell
   git clone https://github.com/YOUR-NAME/orcaslicer-nonplanar.git
   cd orcaslicer-nonplanar
   # copy the .github and windows folders from this package here
   git add .github windows
   git commit -m "Add Windows port"
   git push
   ```

3. On GitHub, open the **Actions** tab and enable workflows for the fork.
4. Choose **Build Windows** > **Run workflow**.
5. When it finishes, download **OrcaSlicer-Nonplanar-Windows-x64** from the bottom
   of the run's page.

The first run takes several hours because all dependencies are built. They are
cached, so later runs are much faster. If a run fails after the `deps` job has
finished, **Re-run failed jobs** continues from the slicer.

## Option 2: build on your PC

Requirements:

- Visual Studio 2022 with **Desktop development with C++**, including
  **C++ CMake tools for Windows**
- Git for Windows
- Strawberry Perl: `winget install StrawberryPerl.StrawberryPerl`
- About 40 GB free on the drive you build on

Open a new PowerShell window in the repository folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\build-windows.ps1 -Tests
```

You can leave Strawberry Perl installed. The script hides its C toolchain
(`C:\Strawberry\c`) from the build, because CMake would otherwise pick up its
MinGW libraries, and it rebuilds anything that was built with them.

The portable ZIP and `build.log` are written to `dist\`. The source goes to `C:\onp\orca`; use
`-SourceDir` to change that (short path, no spaces). Add `-Installer` to also
make an installer (needs [NSIS](https://nsis.sourceforge.io)). To rebuild after a
change without rebuilding the dependencies, use `-Stage slicer`.

## Running it next to a normal OrcaSlicer

Both can be installed and run side by side:

| | OrcaSlicer | OrcaSlicer Nonplanar |
|---|---|---|
| Settings | `%APPDATA%\OrcaSlicer` | `%APPDATA%\OrcaSlicerNonplanar` |
| Install folder | `Program Files\OrcaSlicer` | `Program Files\OrcaSlicer Nonplanar`, or anywhere for the ZIP |
| File types and `orcaslicer://` links | registered | not touched |
| Update check | OrcaSlicer releases | not offered |

Printer and filament profiles are not copied over: the setup wizard runs on the
first start. The Bambu network plug-in is downloaded again, into the new settings
folder.

The app is not code signed, so Windows SmartScreen may warn on the first start:
choose **More info** > **Run anyway**.

## What the Windows patch changes

| Change | Why |
|---|---|
| Own installer name, folder and uninstall key | With the upstream values, the installer uninstalls a normal OrcaSlicer and takes over its folder |
| Facet grouping in `NonplanarSurface` uses a heap stack instead of recursion | Recursion depth grows with the mesh size. Windows gives the main thread 1 MB of stack (macOS: 8 MB) |
| Lambda in `GCode::queue_advanced_conformal` no longer captures a structured binding | That is C++20; the project builds as C++17 |
| Missing standard headers added | They arrive indirectly with Apple's standard library, which MSVC's does not guarantee |
| About box text decoded as UTF-8 | The `·` would otherwise be shown as `Â·` on Windows |
| `" - OrcaSlicer Nonplanar"` in the window title | Tells the two apps apart in the taskbar |
| Version `v0.1-win1` | Shows in the G-code header and the About box, so bug reports identify this build |
| Test for the missing `support-issue.stl` tagged `[missing-fixture]` | The file is not in the repository, so the test cannot run anywhere |

## Testing status

Done without a Windows PC. **No MSVC build has finished yet**, so the first
complete Windows build is the real test of this port.

| Check | Result |
|---|---|
| Both patches apply to OrcaSlicer 2.4.2, including a Windows-style CRLF checkout | Passed |
| All changed core (`libslic3r`) sources compile for a Windows target (MinGW-w64) with `windows.h` included first | Passed |
| Scan of the changed core sources for compiler extensions MSVC rejects (Clang) | Passed, after one fix |
| `[Nonplanar]` tests on x86-64 (Linux, GCC) | 9 of 9 runnable scenarios passed (316 assertions) |
| Installer run in Wine next to a fake OrcaSlicer install | The original settings ran its uninstaller and overwrote its folder. The new ones left it alone |
| Facet grouping on a 1 MB stack, chain-shaped worst case | The old code crashed at 50,000 facets. The new code handled 500,000 |

Not tested:

- A complete compile with MSVC
- Running on real Windows, including the GUI changes
- The PowerShell script has not completed a build yet, and the GitHub workflow
  has not been run (it passed `actionlint`)
- The x86-64 tests used Ubuntu's libraries, including Eigen 3.4 instead of the 5.0.1
  that OrcaSlicer builds with
- Printing

**Check the G-code preview before printing**, as for every test release of this
project. Please do not report problems with this port to the original project
without saying that you use it: the G-code header says `v0.1-win1`.

## License

GNU AGPL-3.0, like OrcaSlicer and the original patch. If you publish a build, also
publish the matching source: the OrcaSlicer commit and both patches.
