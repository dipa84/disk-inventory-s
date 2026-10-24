The first release of Disk Inventory S: [Disk Inventory X](http://www.derlien.com) by Tjark Derlien,
rewritten in Swift for today's Macs. Thank you, Tjark, for the original and for making it free
software.

- **Native and universal**: Apple Silicon and Intel, macOS 15 or later.
- **Fast**: scans on all cores with `getattrlistbulk`. A home folder with 1.2 million files takes
  15 s instead of 12 minutes; a whole 500 GB disk with 3 million files, about 35 s.
- **Counts what is really there**: hard links and APFS clones count once; system volumes, free
  space and unread folders are shown for what they are; system folders that need root can be
  read with the administrator password, read-only.
- **The same cushion treemap**, with zoom, Quick Look, Show in Finder, Move to Trash and Refresh.
- **Settings** for sizes, units, the treemap, scanning and space.
- **Seven languages**: English, Italian, Spanish, French, German, Simplified Chinese, Japanese.

The app is not signed with an Apple Developer ID: the first time, open it from **System Settings ›
Privacy & Security › Open Anyway**, or install it with
`curl -fsSL https://raw.githubusercontent.com/dipa84/disk-inventory-s/main/install.sh | zsh`.

Free software under the GPL 3, and freeware.
