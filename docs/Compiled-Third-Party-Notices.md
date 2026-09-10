# Compiled Distribution Notices

The compiled manager and command line use .NET 10, Windows App SDK 2.4.0, the Windows SDK and Microsoft C#/WinRT projections. The package's `Licenses` directory preserves the exact restored package manifests and supplied license, copyright and notice files. `Licenses/packages.json` records package IDs, versions, declared licenses, copyright metadata and SHA256 hashes of retained files. The inventory includes build/reference dependencies conservatively; it does not imply that every listed assembly is shipped. Runtime packs are included even when NuGet records them separately from ordinary dependencies.

Build tools, reference assemblies, WiX, the test SDK and xUnit are development/test dependencies; they are not runtime PowerShell or C# compilation dependencies of the compiled manager. The original PowerShell distribution retains its SVG.NET 3.4.8 (Microsoft Public License) and ExCSS 4.2.3 (MIT) license texts and notices in the accompanying THIRD-PARTY-NOTICES document. The compiled renderer uses those same versions. Their NuGet packages declare SPDX licenses without embedding license files, so those retained texts also apply to the compiled copies.

Local preview packages are unsigned test artifacts. Package hashes are integrity evidence, not publisher authentication. Production redistribution still requires review of the generated exact-package inventory and the project's authorized signing pipeline. The collector does not provide a legal opinion or infer redistribution rights from a successful build.

## AngleSharp 1.5.0

Source: https://www.nuget.org/packages/AngleSharp/1.5.0

The restored package declares the MIT license and the following copyright. It contains no separate license file; the declared license text is reproduced here.

Copyright 2013-2026, AngleSharp.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.