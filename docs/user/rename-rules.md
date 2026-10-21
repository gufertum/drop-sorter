# Rename rules

A rename rule gives the items moved into a folder a new name, for example a date prefix for an
archive. Folders without a rule keep the names.

## Set a rule

In **Settings › Folders › Rename rules**:

1. **Add Folder…** and choose the folder.
2. Double-click the pattern to edit it, or use **Date Prefix** (`{date}_{time}_{name}{ext}`) or
   **Keep Names** (`{original}`). The Example column shows the result.
3. **Subfolders**: on, the rule also applies to every folder inside; off, only to this exact folder.

When several rules apply, the most specific one wins: a rule on `Archive/Keep` beats the rule on
`Archive`. Use **Keep Names** for a subfolder that should keep its names inside a renamed folder.

The chooser shows **rename** next to folders with a rule, and a preview of the new names.

## Tokens

| Token | Meaning | Example (`invoice.pdf`, 2026-10-10 14:03:22) |
|---|---|---|
| `{date}` | date as `yyyy-MM-dd` | `2026-10-10` |
| `{time}` | time as `HH-mm-ss` | `14-03-22` |
| `{date:FORMAT}` | any date format | `{date:yyyyMMdd-HHmm}` gives `20261010-1403` |
| `{name}` | name without the extension | `invoice` |
| `{ext}` | extension with the dot, empty for folders | `.pdf` |
| `{original}` | the full original name | `invoice.pdf` |

`FORMAT` uses the [ICU date format](https://unicode-org.github.io/icu/userguide/format_parse/datetime/#datetime-format-syntax):
`yyyy` year, `MM` month, `dd` day, `HH` hour, `mm` minute, `ss` second.

- All items of one drop get the same date and time.
- A folder is moved with its content; only the folder itself is renamed.
- A pattern must not produce `/`.
- A name that already exists gets `-2`, `-3` and so on before the extension. Nothing is overwritten.

## Examples

| Pattern | `invoice.pdf` becomes |
|---|---|
| `{date}_{time}_{name}{ext}` | `2026-10-10_14-03-22_invoice.pdf` |
| `{date}_{name}{ext}` | `2026-10-10_invoice.pdf` |
| `{date:yyyy-MM}_{original}` | `2026-10_invoice.pdf` |
| `{original}` | `invoice.pdf` |
