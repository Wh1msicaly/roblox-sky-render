# Acknowledgements

## lualzw by Rochet2

<https://github.com/Rochet2/lualzw>, MIT License, Copyright (c) 2016 Rochet2

The no-HTTP PNG export (`scripts/export_nohttp.luau` and `scripts/assemble_png.py`) compresses
renders with LZW. lualzw was the reference that suggested this approach, and its design was
measured against the final format while choosing it.

**No lualzw code is included in this repository.** The LZW here was written separately for this
use. It differs from lualzw in a few ways:

- It uses codes that grow from 9 to 16 bits, where lualzw uses fixed 2-byte codes.
- It packs its output into 7-bit characters, because bytes 0x80–0xFF don't survive `execute_luau`.
- It works on Luau buffers instead of strings.

lualzw's license is reproduced below for reference and credit.

```text
MIT License

Copyright (c) 2016 Rochet2

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
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Photobooth plugin

The transparent-background technique comes from the Photobooth plugin for Roblox Studio. It
photographs the item against a black and a white backdrop and works out transparency from the
difference. `scripts/render_item.luau` reproduces that technique and does not include any of the
plugin's code.
