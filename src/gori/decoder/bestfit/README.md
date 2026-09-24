# Windows Best-Fit tables

These full codepoint maps are generated from Microsoft's `bestfit<codepage>.txt`
files in Unicode's `Public/MAPPINGS/VENDORS/MICSFT/WindowsBestFit/` directory.
They retain each table's Windows Unicode-to-byte mapping and decode the resulting
bytes through that code page's published byte-to-Unicode table. The TSV rows are
`input-codepoint<TAB>target-codepoint`; an unlisted codepoint uses the page's
default character.

The tables cover the Windows ANSI code pages used by the WorstFit research:
874, 932, 936, 949, 950, and 1250–1258. An input codepoint absent from a page's
table produces that page's default `?` character. The data is compiled into
gori's single binary through `read_file` in `bestfit_data.cr`.

Source: <https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WindowsBestFit/>
Research: <https://blog.orange.tw/posts/2025-01-worstfit-unveiling-hidden-transformers-in-windows-ansi/>

These mappings are Unicode Data Files and are redistributed under Unicode
License v3. See `UNICODE-LICENSE.txt` for the required copyright and permission
notice.
