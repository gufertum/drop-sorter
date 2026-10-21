# How suggestions work

When you drop files, Drop Sorter looks at their names and scores every folder. It only preselects a
folder when the match is clear, so pressing Return without looking never puts a file in the wrong
place.

## What counts

Names are split into words (at separators, at `camelCase` and between letters and digits), lowercased,
and umlauts are spelled out (`Steuererklärung` becomes `steuererklaerung`). Common filler words and bare
numbers are ignored, but years count. Then each word is compared with each folder:

| Signal | Points |
|---|---|
| A word equals the folder name | +3 (a year: +2) |
| A word starts like the folder name (5 or more shared letters) | +2 |
| A word matches an alias of the folder | +2 |
| A word matches a parent folder | +1 |
| The folder already has files with the same name shape and extension | +4, +5 for 2 files, +6 for 3 or more |
| Otherwise: files in the folder share a significant word and the extension | +1, +2 for 3 or more files |
| An extension rule points to the folder | +3 |
| Words like this one were moved to the folder before | +1 per time, at most +4 |

**Name shape** is the strongest signal: months, numbers and dates are placeholders, so
`Dezember_Statement.pdf` looks like `Januar_Statement.pdf` and goes where its siblings already are.

With several items the scores are averaged. A folder is preselected when it scores at least 3 and leads
the next one by at least 1 (both can be changed, see [Configuration](configuration.md#suggest)).

## Learning

Every move teaches Drop Sorter: the words of the moved names count for the folder next time. Settings ›
Advanced › Learning shows how much it has learned; **Forget…** clears it. Undo also takes back what that
drop taught.

## Better suggestions

- **Name folders after what is in them.** "Invoices" matches `invoice-hetzner.pdf`; "Misc" matches
  nothing.
- **Aliases** add words to a folder: `rechnung` and `bill` for an Invoices folder.
- **Extension rules** send file types to a folder: `heic jpg png` to Images.
- **Exclude** folders that should never be suggested, such as caches.
- **Keep files with the same name pattern together.** The name shape signal grows with every file.

Aliases, extension rules and exclusions are set in the [configuration file](configuration.md).
