# Inventario

Che cosa occupa il disco: una mappa a cuscino di ogni file, grande quanto il posto che occupa.
È Disk Inventory X di Tjark Derlien (gitlab.com/tderlien/disk-inventory-x) riscritto in Swift
per i Mac di oggi: nativo per Apple Silicon, e molto più veloce.

| | Disk Inventory X (un filo, NSURL) | Inventario | `du -sk` |
|---|---|---|---|
| /Applications, 600 000 file | 158 s | 3,9 s | 21 s |
| cartella Inizio, 1,2 milioni di file | 723 s | 15,5 s | 103 s |
| disco intero, 3 milioni di file | — | 34 s | — |

(M1, 8 core; la stessa scansione, a cache calda dove indicato nel registro dei commit.)

## Che cosa cambia rispetto all'originale

- La scansione legge ogni cartella con `getattrlistbulk` (molte voci per chiamata, con nome, tipo
  e dimensioni insieme) su tutti i core; somme e ordinamenti si fanno in parallelo man mano che le
  cartelle finiscono.
- I collegamenti fissi e i cloni di APFS contano una volta sola: l'originale (e il Finder) contano
  ogni clone per intero, e su un disco con le copie che Chrome lascia in `/private/var/folders`
  arrivava a più del triplo del disco.
- I volumi montati dentro la cartella non si attraversano, i firmlink sì (come l'originale).
- La mappa è la stessa (TMVItem e TMVCushionRenderer), disegnata a strisce su tutti i core.

## Comandi

| | |
|---|---|
| clic | sceglie il file |
| doppio clic | entra nella cartella sotto il puntatore |
| ← → ↑ ↓ | il riquadro accanto, allo stesso livello |
| ⇧ e le frecce | il riquadro accanto, al livello della cartella sopra |
| ⌘↑ / ⌘↓ | sceglie la cartella sopra / la voce più grande dentro |
| ↩ | entra nella cartella scelta |
| ⌘[ / ⌘] / ⇧⌘[ | esce di un livello / torna dentro / tutta la cartella |
| spazio, ⌘Y | Anteprima |
| ⌘R | Mostra nel Finder |
| ⌥⌘C | copia il percorso |
| ⇧⌘R | rilegge dal disco la cartella scelta |
| ⌘⌫ | sposta nel Cestino (chiede conferma) |

Scegliere un tipo di file nell'elenco in basso lo mette in evidenza nella mappa.

## Costruire

Bastano gli strumenti da riga di comando (Swift 6), non serve Xcode.

    tools/inventario-app.sh             # .build/Inventario.app
    tools/inventario-app.sh --installa  # anche in /Applications
    swift run -c release inventario-prove
    swift run -c release inventario-cli scan ~      # i tempi della scansione

`INVENTARIO_MISURA=1` stampa i tempi di scansione e disegno; `INVENTARIO_FOTO=file.png` salva
un'immagine della finestra dopo la scansione ed esce.

Per leggere anche Mail, Messaggi, Safari e le altre cartelle protette, Inventario ha bisogno
dell'Accesso completo al disco (Impostazioni di Sistema › Privacy e sicurezza).

## Licenza

GPL 3, come Disk Inventory X (COPYING).
