# Disk Inventory S

What is taking up the disk: a cushion treemap of every file, each as big as the space it takes.
It is Disk Inventory X by Tjark Derlien (gitlab.com/tderlien/disk-inventory-x) rewritten in Swift
for today's Macs: native on Apple Silicon, and much faster. The S stands for Swift.

This is a modified version, not the author's: rewritten by Riccardo Di Paola in 2026 (the GPL asks
to say so). The treemap layout and drawing come from the original's TMVItem.m and
TMVCushionRenderer.m; scanning, model and interface are new.

| | Disk Inventory X (one thread, NSURL) | Disk Inventory S | `du -sk` |
|---|---|---|---|
| /Applications, 600,000 files | 158 s | 3.9 s | 21 s |
| home folder, 1.2 million files | 723 s | 15.5 s | 103 s |
| whole disk, 3 million files | — | 34 s | — |

(M1, 8 cores.)

## What changes from the original

- The scan reads each folder with `getattrlistbulk` (many entries per call, with name, type and
  sizes together) on all cores; sums and sorting happen in parallel as folders finish.
- Hard links and APFS clones count only once. The original (and the Finder) count each clone in
  full: on a disk holding the copies Chrome leaves in `/private/var/folders` it came to more than
  three times the disk.
- Volumes mounted inside the folder are not traversed; firmlinks are (as in the original).
- The treemap is the same (TMVItem and TMVCushionRenderer), drawn in bands on all cores.

## Commands

| | |
|---|---|
| click | selects the file |
| double click | goes into the folder under the pointer |
| ← → ↑ ↓ | the neighboring tile, at the same level |
| ⇧ and the arrows | the neighboring tile, at the level of the folder above |
| ⌘↑ / ⌘↓ | selects the enclosing folder / the largest entry inside |
| ↩ | goes into the selected folder |
| ⌘[ / ⌘] / ⇧⌘[ | goes out one level / back in / the whole folder |
| space, ⌘Y | Quick Look |
| ⌘R | Show in Finder |
| ⌥⌘C | copies the path |
| ⇧⌘R | rereads the selected folder from disk |
| ⌘⌫ | moves to the Trash (asks first) |

Selecting a file kind in the list at the bottom highlights it in the treemap.

## Space that is not in files

When reading a whole disk, the treemap also shows entries that are not files:

- **Free Space**: what is still available (purgeable space can be added in the settings, but it
  counts twice the iCloud files that are also in the treemap);
- **System Volumes**: the other volumes of the same APFS container (virtual memory, Preboot,
  Recovery, updates), measured one by one with `diskutil apfs list`;
- **Folders Not Read**: the space of the folders an app cannot open. System ones (the Spotlight
  index, document versions, `/private/var/db`…) belong to root: the button at the bottom of the
  window has the helper (`dis-cli export`, inside the app) read them with the administrator
  password, read-only, and puts them in the treemap with their names. Private ones (Mail,
  Messages…) need Full Disk Access;
- **File System Data**: once everything was read, what remains (APFS indexes and tables).

Reading “/” also reads the data volume (`/System/Volumes/Data`), skipping the folders the firmlinks
lead to, already counted from “/”: some things live only there, like `macOS Install Data`.

The original put all of this into a single “Other space”.

## Settings (⌘,)

General (size, decimal or binary units, Trash confirmation, what to open at launch, language),
Map (cushion relief and light, lines between files, frame under the pointer, 12 or 24 colored
kinds), Scan (clones and hard links once, other volumes, packages, folders to skip), Space.

## Languages

English, Italian, Spanish, French, German, Simplified Chinese, Japanese. The strings live in
`tools/translations.py`, which writes the `.strings` files and stops if the code passes a string to
`L()` without a translation. File kind names come from macOS, in the app's language.

## Building

The command line tools (Swift 6) are enough; Xcode is not needed.

    tools/make-certificate.sh          # once per Mac: a local signing certificate
    tools/build-app.sh                 # .build/Disk Inventory S.app
    tools/build-app.sh --install       # also into /Applications
    swift run -c release dis-tests
    swift run -c release dis-cli scan ~    # scan timings

The local certificate keeps macOS privacy permissions from one build to the next: signed ad hoc,
every build looks like a new app to macOS, which asks for them again.

`DIS_TIMING=1` prints scan and drawing times; `DIS_PHOTO=file.png` saves an image of the window
after the scan and quits (`DIS_ACTIONS=selectChild,zoomIn` runs menu actions first).

## License

GPL 3, like Disk Inventory X (COPYING).
