Scripts that were created for small tasks or repeated tasks or one-off tasks.
You can read the scripts before running just in case. 
| Script | What it does |
|---|---|
| `XCrop.ps1` | Crops an image to an e-ink panel spec (X3 528x792, X4 480x800) and writes an uncompressed 24-bit BMP. WinForms GUI: grayscale preview, aspect-locked crop box, bright/contrast/invert. |
| `album-review.ps1` | Keep/delete review of a music library, one album at a time, with cover art. K keeps, D deletes, Backspace undoes. Decisions are saved after every click, so it's resumable; nothing is removed until you confirm at the end, and deletes go to the Recycle Bin. |
| `epub_fix_vn.py` | Repairs publisher-side text encoding damage in EPUBs — mislabelled cp1252/latin-1, mojibake, and decomposed (NFD) Vietnamese that bitmap-glyph e-readers can't compose. Fixes only the runs that are genuinely broken. |

## Running

```powershell
.\XCrop.ps1 photo.jpg
Get-Help .\XCrop.ps1 -Full          # PowerShell scripts document themselves
```

```bash
uv run epub_fix_vn.py book.epub     # deps come from the inline script metadata
```

`album-review.ps1` treats its own directory as the library root — drop it in the
music folder you want to review.

If Windows blocks a downloaded script: `powershell -ExecutionPolicy Bypass -File .\XCrop.ps1`
