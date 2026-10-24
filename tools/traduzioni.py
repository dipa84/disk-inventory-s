#!/usr/bin/env python3
"""Le traduzioni dell'interfaccia: una tabella sola, dall'italiano alle altre sei lingue.

Scrive assets/macos/Localizations/<lingua>.lproj/Localizable.strings (e InfoPlist.strings) e
controlla che ogni frase passata a L() nel codice sia tradotta in tutte le lingue: se ne manca
una si ferma, e tools/inventario-app.sh con lui.

Le chiavi sono le frasi italiane. Quelle con «(molti)» sono il plurale di una frase (vedi L(one:other:)
in Sources/InventarioCore/Localization.swift): in italiano la traduzione toglie solo il segno.
"""
import glob
import os
import re
import sys

LINGUE = ["en", "es", "fr", "de", "zh-Hans", "ja"]

# frase italiana: (inglese, spagnolo, francese, tedesco, cinese semplificato, giapponese)
T = {
    # la barra in basso
    "%@ cartella non leggibile…": ("%@ unreadable folder…", "%@ carpeta no legible…", "%@ dossier illisible…", "%@ nicht lesbarer Ordner …", "%@ 个文件夹无法读取…", "読み取れないフォルダ %@ 個…"),
    "%@ cartelle non leggibili…": ("%@ unreadable folders…", "%@ carpetas no legibles…", "%@ dossiers illisibles…", "%@ nicht lesbare Ordner …", "%@ 个文件夹无法读取…", "読み取れないフォルダ %@ 個…"),
    "%@ file, %@": ("%@ file, %@", "%@ archivo, %@", "%@ fichier, %@", "%@ Datei, %@", "%@ 个文件，%@", "%@ 個のファイル、%@"),
    "%@ file, %@ (molti)": ("%@ files, %@", "%@ archivos, %@", "%@ fichiers, %@", "%@ Dateien, %@", "%@ 个文件，%@", "%@ 個のファイル、%@"),
    "letti in %@": ("read in %@", "leídos en %@", "lus en %@", "gelesen in %@", "用时 %@", "読み込み %@"),
    "Per leggere tutto, Disk Inventory S ha bisogno dell'Accesso completo al disco (Impostazioni di Sistema › Privacy e sicurezza).": (
        "To read everything, Disk Inventory S needs Full Disk Access (System Settings › Privacy & Security).",
        "Para leerlo todo, Disk Inventory S necesita Acceso total al disco (Ajustes del Sistema › Privacidad y seguridad).",
        "Pour tout lire, Disk Inventory S a besoin de l’accès complet au disque (Réglages Système › Confidentialité et sécurité).",
        "Um alles zu lesen, braucht Disk Inventory S den Festplattenvollzugriff (Systemeinstellungen › Datenschutz & Sicherheit).",
        "要读取全部内容，Disk Inventory S 需要“完全磁盘访问权限”（系统设置 › 隐私与安全性）。",
        "すべてを読み込むには、Disk Inventory S に「フルディスクアクセス」が必要です（システム設定 › プライバシーとセキュリティ）。"),
    "%@ file": ("%@ file", "%@ archivo", "%@ fichier", "%@ Datei", "%@ 个文件", "%@ 個のファイル"),
    "%@ file (molti)": ("%@ files", "%@ archivos", "%@ fichiers", "%@ Dateien", "%@ 个文件", "%@ 個のファイル"),
    "Rileggo %@…": ("Rereading %@…", "Volviendo a leer %@…", "Relecture de %@…", "%@ wird neu gelesen …", "正在重新读取 %@…", "%@ を再読み込み中…"),

    # il Cestino
    "Spostare «%@» nel Cestino?": ("Move “%@” to the Trash?", "¿Trasladar «%@» a la Papelera?", "Placer « %@ » dans la Corbeille ?", "„%@“ in den Papierkorb legen?", "要将“%@”移到废纸篓吗？", "“%@”をゴミ箱に入れますか？"),
    "Sposta nel Cestino": ("Move to Trash", "Trasladar a la Papelera", "Placer dans la Corbeille", "In den Papierkorb legen", "移到废纸篓", "ゴミ箱に入れる"),
    "Annulla": ("Cancel", "Cancelar", "Annuler", "Abbrechen", "取消", "キャンセル"),
    "Non chiedere più": ("Don’t ask again", "No volver a preguntar", "Ne plus demander", "Nicht mehr fragen", "不再询问", "今後確認しない"),
    "Cestino": ("Trash", "Papelera", "Corbeille", "Papierkorb", "废纸篓", "ゴミ箱"),
    "Sposta nel Cestino (⌘⌫)": ("Move to Trash (⌘⌫)", "Trasladar a la Papelera (⌘⌫)", "Placer dans la Corbeille (⌘⌫)", "In den Papierkorb legen (⌘⌫)", "移到废纸篓 (⌘⌫)", "ゴミ箱に入れる (⌘⌫)"),

    # la scelta
    "Apri": ("Open", "Abrir", "Ouvrir", "Öffnen", "打开", "開く"),
    "Mostra nel Finder": ("Show in Finder", "Mostrar en el Finder", "Afficher dans le Finder", "Im Finder zeigen", "在访达中显示", "Finderに表示"),
    "Mostra nel Finder (⌘R)": ("Show in Finder (⌘R)", "Mostrar en el Finder (⌘R)", "Afficher dans le Finder (⌘R)", "Im Finder zeigen (⌘R)", "在访达中显示 (⌘R)", "Finderに表示 (⌘R)"),
    "Anteprima": ("Quick Look", "Vista rápida", "Coup d’œil", "Übersicht", "快速查看", "クイックルック"),
    "Entra": ("Go In", "Entrar", "Entrer", "Hineingehen", "进入", "中に入る"),
    "Aggiorna": ("Refresh", "Actualizar", "Actualiser", "Aktualisieren", "刷新", "更新"),
    "Aggiorna tutto": ("Refresh All", "Actualizar todo", "Tout actualiser", "Alles aktualisieren", "全部刷新", "すべて更新"),
    "Copia il percorso": ("Copy Path", "Copiar la ruta", "Copier le chemin", "Pfad kopieren", "拷贝路径", "パスをコピー"),
    "Esci": ("Go Out", "Salir", "Sortir", "Hinausgehen", "退出文件夹", "外に出る"),
    "Esci / Entra": ("Out / In", "Salir / Entrar", "Sortir / Entrer", "Hinaus / Hinein", "退出 / 进入", "外へ / 中へ"),
    "Esci dalla cartella (⌘[) / Entra nella scelta (↩)": (
        "Go out of the folder (⌘[) / Go into the selection (↩)", "Salir de la carpeta (⌘[) / Entrar en la selección (↩)",
        "Sortir du dossier (⌘[) / Entrer dans la sélection (↩)", "Ordner verlassen (⌘[) / In die Auswahl gehen (↩)",
        "退出文件夹 (⌘[) / 进入所选项 (↩)", "フォルダの外へ (⌘[) / 選択項目の中へ (↩)"),
    "Cartella mostrata": ("Folder Shown", "Carpeta mostrada", "Dossier affiché", "Angezeigter Ordner", "显示的文件夹", "表示中のフォルダ"),
    "Rileggi dal disco la cartella scelta (⇧⌘R)": ("Reread the selected folder from disk (⇧⌘R)", "Volver a leer del disco la carpeta seleccionada (⇧⌘R)", "Relire depuis le disque le dossier sélectionné (⇧⌘R)", "Ausgewählten Ordner neu vom Volume lesen (⇧⌘R)", "从磁盘重新读取所选文件夹 (⇧⌘R)", "選択したフォルダをディスクから再読み込み (⇧⌘R)"),

    # la lettura
    "Leggo %@": ("Reading %@", "Leyendo %@", "Lecture de %@", "%@ wird gelesen", "正在读取 %@", "%@ を読み込み中"),
    "%@ file in %@ cartelle · %@": ("%@ files in %@ folders · %@", "%@ archivos en %@ carpetas · %@", "%@ fichiers dans %@ dossiers · %@", "%@ Dateien in %@ Ordnern · %@", "%@ 个文件，%@ 个文件夹 · %@", "%@ 個のファイル、%@ 個のフォルダ · %@"),
    "Annullo…": ("Cancelling…", "Cancelando…", "Annulation…", "Wird abgebrochen …", "正在取消…", "キャンセル中…"),

    # le colonne
    "Nome": ("Name", "Nombre", "Nom", "Name", "名称", "名前"),
    "Dimensione": ("Size", "Tamaño", "Taille", "Größe", "大小", "サイズ"),
    "Tipo": ("Kind", "Tipo", "Type", "Art", "种类", "種類"),
    "File": ("Files", "Archivos", "Fichiers", "Dateien", "文件", "ファイル"),

    # le voci particolari
    "lo spazio ancora disponibile": ("the space still available", "el espacio aún disponible", "l’espace encore disponible", "der noch verfügbare Platz", "仍然可用的空间", "まだ使える領域"),
    "memoria virtuale, Preboot, Recovery, aggiornamenti di macOS": ("virtual memory, Preboot, Recovery, macOS updates", "memoria virtual, Preboot, Recovery, actualizaciones de macOS", "mémoire virtuelle, Preboot, Recovery, mises à jour de macOS", "virtueller Speicher, Preboot, Recovery, macOS-Updates", "虚拟内存、Preboot、Recovery、macOS 更新", "仮想メモリ、Preboot、Recovery、macOSアップデート"),
    "cartelle protette, istantanee di Time Machine, dati del file system": ("protected folders, Time Machine snapshots, file system data", "carpetas protegidas, instantáneas de Time Machine, datos del sistema de archivos", "dossiers protégés, instantanés Time Machine, données du système de fichiers", "geschützte Ordner, Time Machine-Snapshots, Dateisystemdaten", "受保护的文件夹、时间机器快照、文件系统数据", "保護されたフォルダ、Time Machineのスナップショット、ファイルシステムのデータ"),
    "non leggibile: serve l'Accesso completo al disco": ("unreadable: needs Full Disk Access", "no legible: necesita Acceso total al disco", "illisible : nécessite l’accès complet au disque", "nicht lesbar: Festplattenvollzugriff nötig", "无法读取：需要“完全磁盘访问权限”", "読み取れません：フルディスクアクセスが必要です"),
    "un altro volume: non è contato qui": ("another volume: not counted here", "otro volumen: no se cuenta aquí", "un autre volume : non compté ici", "ein anderes Volume: hier nicht gezählt", "另一个宗卷：不在此处计算", "別のボリューム：ここでは数えません"),
    "è la stessa cartella che si vede da / (firmlink): contata là": ("the same folder seen from / (firmlink): counted there", "es la misma carpeta que se ve desde / (firmlink): contada allí", "c’est le même dossier vu depuis / (firmlink) : compté là-bas", "derselbe Ordner wie unter / (Firmlink): dort gezählt", "与从 / 看到的是同一个文件夹（固定链接）：在那里计算", "/ から見えるのと同じフォルダ（ファームリンク）：そちらで数えます"),
    "saltata (Impostazioni › Scansione)": ("skipped (Settings › Scan)", "omitida (Ajustes › Análisis)", "ignoré (Réglages › Analyse)", "übersprungen (Einstellungen › Scan)", "已跳过（设置 › 扫描）", "スキップ（設定 › スキャン）"),
    "un altro nome di un file già contato altrove": ("another name of a file already counted elsewhere", "otro nombre de un archivo ya contado en otro lugar", "un autre nom d’un fichier déjà compté ailleurs", "ein weiterer Name einer bereits gezählten Datei", "已在别处计算的文件的另一个名称", "ほかの場所で数えたファイルの別名"),
    "un clone: conta solo quello che ha di suo": ("a clone: only its own data counts", "un clon: solo cuenta lo que tiene de propio", "un clone : seul ce qui lui est propre compte", "ein Klon: zählt nur seine eigenen Daten", "克隆：只计算其独有的数据", "クローン：独自のデータだけを数えます"),
    "Spazio libero": ("Free Space", "Espacio libre", "Espace libre", "Freier Speicher", "可用空间", "空き領域"),
    "Volumi di sistema": ("System Volumes", "Volúmenes del sistema", "Volumes système", "Systemvolumes", "系统宗卷", "システムボリューム"),
    "Spazio nascosto": ("Hidden Space", "Espacio oculto", "Espace caché", "Versteckter Speicher", "隐藏空间", "隠れた領域"),
    "File .%@": (".%@ File", "Archivo .%@", "Fichier .%@", ".%@-Datei", ".%@ 文件", ".%@ ファイル"),

    # le impostazioni
    "Impostazioni": ("Settings", "Ajustes", "Réglages", "Einstellungen", "设置", "設定"),
    "Generale": ("General", "General", "Général", "Allgemein", "通用", "一般"),
    "Mappa": ("Map", "Mapa", "Carte", "Karte", "图", "マップ"),
    "Scansione": ("Scan", "Análisis", "Analyse", "Scan", "扫描", "スキャン"),
    "Spazio": ("Space", "Espacio", "Espace", "Speicher", "空间", "領域"),
    "Su disco (quello che si libera cancellando)": ("On disk (what deleting frees)", "En disco (lo que se libera al borrar)", "Sur le disque (ce que libère la suppression)", "Auf dem Volume (was Löschen freigibt)", "占用磁盘（删除后释放的空间）", "ディスク上（削除すると空く量）"),
    "Logica (la lunghezza del contenuto)": ("Logical (the length of the content)", "Lógico (la longitud del contenido)", "Logique (la longueur du contenu)", "Logisch (die Länge des Inhalts)", "逻辑大小（内容的长度）", "論理サイズ（内容の長さ）"),
    "Per le finestre nuove; in una finestra aperta si cambia dal menu Vista.": ("For new windows; in an open window, change it from the View menu.", "Para las ventanas nuevas; en una ventana abierta se cambia desde el menú Visualización.", "Pour les nouvelles fenêtres ; dans une fenêtre ouverte, changez-le dans le menu Présentation.", "Für neue Fenster; in einem offenen Fenster im Menü „Darstellung“ ändern.", "用于新窗口；在打开的窗口中可从“显示”菜单更改。", "新しいウインドウ用。開いているウインドウでは「表示」メニューで変更します。"),
    "Unità": ("Units", "Unidades", "Unités", "Einheiten", "单位", "単位"),
    "Decimali: 1 GB = 1000 MB, come il Finder": ("Decimal: 1 GB = 1000 MB, like the Finder", "Decimales: 1 GB = 1000 MB, como el Finder", "Décimales : 1 Go = 1000 Mo, comme le Finder", "Dezimal: 1 GB = 1000 MB, wie der Finder", "十进制：1 GB = 1000 MB，与访达一致", "10進：1 GB = 1000 MB（Finderと同じ）"),
    "Binarie: 1 GiB = 1024 MiB": ("Binary: 1 GiB = 1024 MiB", "Binarias: 1 GiB = 1024 MiB", "Binaires : 1 Gio = 1024 Mio", "Binär: 1 GiB = 1024 MiB", "二进制：1 GiB = 1024 MiB", "2進：1 GiB = 1024 MiB"),
    "Chiedi conferma prima di spostare nel Cestino": ("Ask before moving to the Trash", "Preguntar antes de trasladar a la Papelera", "Demander avant de placer dans la Corbeille", "Vor dem Bewegen in den Papierkorb fragen", "移到废纸篓前询问", "ゴミ箱に入れる前に確認する"),
    "All'avvio": ("At launch", "Al abrir", "Au démarrage", "Beim Start", "启动时", "起動時"),
    "La finestra dei dischi": ("The disks window", "La ventana de los discos", "La fenêtre des disques", "Das Fenster mit den Volumes", "磁盘窗口", "ディスクのウインドウ"),
    "L'ultima cartella letta": ("The last folder read", "La última carpeta leída", "Le dernier dossier lu", "Den zuletzt gelesenen Ordner", "上次读取的文件夹", "最後に読み込んだフォルダ"),
    "Niente": ("Nothing", "Nada", "Rien", "Nichts", "无", "何もしない"),
    "Lingua": ("Language", "Idioma", "Langue", "Sprache", "语言", "言語"),
    "La lingua cambia al prossimo avvio.": ("The language changes at the next launch.", "El idioma cambia la próxima vez que se abra.", "La langue change au prochain démarrage.", "Die Sprache ändert sich beim nächsten Start.", "语言将在下次启动时更改。", "言語は次回の起動時に変わります。"),
    "Riavvia ora": ("Relaunch Now", "Reabrir ahora", "Relancer maintenant", "Jetzt neu starten", "立即重新启动", "今すぐ再起動"),
    "Come il sistema": ("Same as the system", "Como el sistema", "Comme le système", "Wie das System", "跟随系统", "システムと同じ"),
    "Rilievo dei cuscini": ("Cushion relief", "Relieve de los cojines", "Relief des coussins", "Relief der Kissen", "垫面起伏", "クッションの起伏"),
    "piatti": ("flat", "planos", "plats", "flach", "平", "平ら"),
    "alti": ("high", "altos", "hauts", "hoch", "高", "高い"),
    "Luce nelle ombre": ("Light in the shadows", "Luz en las sombras", "Lumière dans les ombres", "Licht in den Schatten", "阴影亮度", "影の明るさ"),
    "scure": ("dark", "oscuras", "sombres", "dunkel", "暗", "暗い"),
    "chiare": ("light", "claras", "claires", "hell", "亮", "明るい"),
    "Una riga scura fra un file e l'altro": ("A dark line between files", "Una línea oscura entre un archivo y otro", "Une ligne sombre entre les fichiers", "Eine dunkle Linie zwischen den Dateien", "文件之间显示深色分隔线", "ファイルの間に暗い線"),
    "Un bordo sul file sotto il puntatore": ("A frame on the file under the pointer", "Un borde en el archivo bajo el puntero", "Un cadre sur le fichier sous le pointeur", "Ein Rahmen um die Datei unter dem Zeiger", "为指针下的文件加边框", "ポインタの下のファイルに枠"),
    "Tipi colorati": ("Colored kinds", "Tipos con color", "Types en couleur", "Farbige Arten", "彩色种类", "色付きの種類"),
    "I 12 più grandi (come l'originale)": ("The 12 largest (like the original)", "Los 12 más grandes (como el original)", "Les 12 plus grands (comme l’original)", "Die 12 größten (wie das Original)", "最大的 12 种（与原版相同）", "大きい順に12種類（オリジナルと同じ）"),
    "I 24 più grandi": ("The 24 largest", "Los 24 más grandes", "Les 24 plus grands", "Die 24 größten", "最大的 24 种", "大きい順に24種類"),
    "Gli altri tipi sono grigi.": ("The other kinds are gray.", "Los demás tipos son grises.", "Les autres types sont gris.", "Die anderen Arten sind grau.", "其他种类显示为灰色。", "ほかの種類はグレーです。"),
    "Come l'originale": ("Like the Original", "Como el original", "Comme l’original", "Wie das Original", "恢复原版设置", "オリジナルと同じにする"),
    "Conta una volta sola i cloni di APFS e i collegamenti fissi": ("Count APFS clones and hard links only once", "Contar una sola vez los clones de APFS y los enlaces físicos", "Compter une seule fois les clones APFS et les liens physiques", "APFS-Klone und harte Links nur einmal zählen", "APFS 克隆和硬链接只计算一次", "APFSのクローンとハードリンクは1回だけ数える"),
    "Come du. Il Finder e Disk Inventory X li contano ogni volta, e un disco può sembrare più pieno di quanto sia.": (
        "Like du. The Finder and Disk Inventory X count them every time, and a disk can look fuller than it is.",
        "Como du. El Finder y Disk Inventory X los cuentan cada vez, y un disco puede parecer más lleno de lo que está.",
        "Comme du. Le Finder et Disk Inventory X les comptent à chaque fois, et un disque peut sembler plus plein qu’il ne l’est.",
        "Wie du. Der Finder und Disk Inventory X zählen sie jedes Mal, und ein Volume kann voller wirken, als es ist.",
        "与 du 相同。访达和 Disk Inventory X 每次都会计算它们，磁盘可能看起来比实际更满。",
        "duと同じです。FinderとDisk Inventory Xは毎回数えるため、ディスクが実際より満杯に見えることがあります。"),
    "Entra negli altri volumi (dischi esterni) dentro la cartella": ("Go into other volumes (external disks) inside the folder", "Entrar en otros volúmenes (discos externos) dentro de la carpeta", "Entrer dans les autres volumes (disques externes) du dossier", "Andere Volumes (externe Festplatten) im Ordner einbeziehen", "进入文件夹中的其他宗卷（外置磁盘）", "フォルダ内のほかのボリューム（外部ディスク）にも入る"),
    "Apri i pacchetti (applicazioni, librerie di Foto…)": ("Open packages (apps, Photos libraries…)", "Abrir los paquetes (apps, fototecas…)", "Ouvrir les paquets (apps, photothèques…)", "Pakete öffnen (Apps, Fotos-Mediatheken …)", "打开包（应用、照片图库…）", "パッケージを開く（アプリ、写真ライブラリ…）"),
    "Cartelle da saltare": ("Folders to skip", "Carpetas que omitir", "Dossiers à ignorer", "Zu überspringende Ordner", "要跳过的文件夹", "スキップするフォルダ"),
    "Nomi separati da virgole. Restano nella mappa come cartelle vuote.": ("Names separated by commas. They stay in the map as empty folders.", "Nombres separados por comas. Quedan en el mapa como carpetas vacías.", "Noms séparés par des virgules. Ils restent dans la carte comme des dossiers vides.", "Namen durch Kommas getrennt. Sie bleiben als leere Ordner in der Karte.", "名称以逗号分隔。它们在图中显示为空文件夹。", "名前をカンマで区切ります。マップには空のフォルダとして残ります。"),
    "Queste scelte valgono dalla prossima lettura.": ("These choices apply from the next scan.", "Estas opciones se aplican a partir de la próxima lectura.", "Ces choix s’appliquent à partir de la prochaine lecture.", "Diese Einstellungen gelten ab dem nächsten Lesen.", "这些选项从下次读取开始生效。", "これらの設定は次回の読み込みから有効です。"),
    "Quando leggo un disco intero, mostra anche lo spazio che non è nei file": ("When reading a whole disk, also show the space that isn’t in files", "Al leer un disco entero, mostrar también el espacio que no está en archivos", "Lors de la lecture d’un disque entier, afficher aussi l’espace hors fichiers", "Beim Lesen eines ganzen Volumes auch den Speicher außerhalb von Dateien zeigen", "读取整个磁盘时，也显示不在文件中的空间", "ディスク全体を読み込むとき、ファイル以外の領域も表示する"),
    "lo spazio ancora disponibile.": ("the space still available.", "el espacio aún disponible.", "l’espace encore disponible.", "der noch verfügbare Platz.", "仍然可用的空间。", "まだ使える領域。"),
    "gli altri volumi dello stesso disco: memoria virtuale, Preboot, Recovery, aggiornamenti di macOS.": (
        "the disk’s other volumes: virtual memory, Preboot, Recovery, macOS updates.",
        "los otros volúmenes del mismo disco: memoria virtual, Preboot, Recovery, actualizaciones de macOS.",
        "les autres volumes du même disque : mémoire virtuelle, Preboot, Recovery, mises à jour de macOS.",
        "die anderen Volumes derselben Festplatte: virtueller Speicher, Preboot, Recovery, macOS-Updates.",
        "同一磁盘上的其他宗卷：虚拟内存、Preboot、Recovery、macOS 更新。",
        "同じディスクのほかのボリューム：仮想メモリ、Preboot、Recovery、macOSアップデート。"),
    "occupato ma non leggibile come file: cartelle protette (con l'Accesso completo al disco diventa più piccolo), istantanee di Time Machine, dati del file system.": (
        "used but not readable as files: protected folders (it shrinks with Full Disk Access), Time Machine snapshots, file system data.",
        "ocupado pero no legible como archivos: carpetas protegidas (con Acceso total al disco se reduce), instantáneas de Time Machine, datos del sistema de archivos.",
        "occupé mais illisible sous forme de fichiers : dossiers protégés (il diminue avec l’accès complet au disque), instantanés Time Machine, données du système de fichiers.",
        "belegt, aber nicht als Dateien lesbar: geschützte Ordner (mit Festplattenvollzugriff wird er kleiner), Time Machine-Snapshots, Dateisystemdaten.",
        "已占用但无法作为文件读取：受保护的文件夹（获得“完全磁盘访问权限”后会变小）、时间机器快照、文件系统数据。",
        "使用中だがファイルとして読めない領域：保護されたフォルダ（フルディスクアクセスで小さくなります）、Time Machineのスナップショット、ファイルシステムのデータ。"),
    "Conta come libero anche lo spazio eliminabile, come il Finder": ("Count purgeable space as free too, like the Finder", "Contar también como libre el espacio purgable, como el Finder", "Compter aussi l’espace purgeable comme libre, comme le Finder", "Auch löschbaren Speicher als frei zählen, wie der Finder", "将可清除空间也算作可用，与访达一致", "パージ可能な領域も空きとして数える（Finderと同じ）"),
    "Lo spazio eliminabile (cache, copie locali di iCloud) il sistema lo libera da sé quando serve.": (
        "The system frees purgeable space (caches, local iCloud copies) by itself when needed.",
        "El sistema libera por sí mismo el espacio purgable (cachés, copias locales de iCloud) cuando hace falta.",
        "Le système libère lui-même l’espace purgeable (caches, copies locales iCloud) quand il le faut.",
        "Das System gibt löschbaren Speicher (Caches, lokale iCloud-Kopien) bei Bedarf selbst frei.",
        "系统会在需要时自行释放可清除空间（缓存、iCloud 本地副本）。",
        "パージ可能な領域（キャッシュ、iCloudのローカルコピー）は、必要なときにシステムが自動で解放します。"),

    # l'apertura e i menu
    "Leggi": ("Read", "Leer", "Lire", "Lesen", "读取", "読み込む"),
    "Scegli la cartella o il disco da esaminare": ("Choose the folder or disk to examine", "Elige la carpeta o el disco que examinar", "Choisissez le dossier ou le disque à examiner", "Wähle den Ordner oder das Volume", "选择要检查的文件夹或磁盘", "調べるフォルダまたはディスクを選択してください"),
    "Informazioni su %@": ("About %@", "Acerca de %@", "À propos de %@", "Über %@", "关于%@", "%@について"),
    "Impostazioni…": ("Settings…", "Ajustes…", "Réglages…", "Einstellungen …", "设置…", "設定…"),
    "Nascondi %@": ("Hide %@", "Ocultar %@", "Masquer %@", "%@ ausblenden", "隐藏%@", "%@を非表示"),
    "Nascondi altre": ("Hide Others", "Ocultar otros", "Masquer les autres", "Andere ausblenden", "隐藏其他", "ほかを非表示"),
    "Mostra tutte": ("Show All", "Mostrar todo", "Tout afficher", "Alle einblenden", "全部显示", "すべてを表示"),
    "Esci da %@": ("Quit %@", "Salir de %@", "Quitter %@", "%@ beenden", "退出%@", "%@を終了"),
    "Archivio": ("File", "Archivo", "Fichier", "Ablage", "文件", "ファイル"),
    "Leggi una cartella…": ("Read a Folder…", "Leer una carpeta…", "Lire un dossier…", "Ordner lesen …", "读取文件夹…", "フォルダを読み込む…"),
    "Dischi": ("Disks", "Discos", "Disques", "Volumes", "磁盘", "ディスク"),
    "Chiudi": ("Close", "Cerrar", "Fermer", "Schließen", "关闭", "閉じる"),
    "Modifica": ("Edit", "Edición", "Édition", "Bearbeiten", "编辑", "編集"),
    "Scelta": ("Item", "Elemento", "Élément", "Objekt", "项目", "項目"),
    "Scegli la cartella che la contiene": ("Select Enclosing Folder", "Seleccionar la carpeta contenedora", "Sélectionner le dossier parent", "Übergeordneten Ordner auswählen", "选择所在文件夹", "上のフォルダを選択"),
    "Scegli la voce più grande dentro": ("Select Largest Item Inside", "Seleccionar el elemento más grande de dentro", "Sélectionner le plus grand élément à l’intérieur", "Größtes Objekt darin auswählen", "选择其中最大的项目", "中で一番大きい項目を選択"),
    "Vista": ("View", "Visualización", "Présentation", "Darstellung", "显示", "表示"),
    "Entra nella scelta": ("Go Into Selection", "Entrar en la selección", "Entrer dans la sélection", "In die Auswahl gehen", "进入所选项", "選択項目の中へ"),
    "Esci dalla cartella": ("Go Out of Folder", "Salir de la carpeta", "Sortir du dossier", "Ordner verlassen", "退出文件夹", "フォルダの外へ"),
    "Torna dentro": ("Go Back In", "Volver a entrar", "Revenir dedans", "Wieder hineingehen", "返回内部", "もう一度中へ"),
    "Tutta la cartella": ("Whole Folder", "Toda la carpeta", "Dossier entier", "Ganzer Ordner", "整个文件夹", "フォルダ全体"),
    "Dimensione logica (invece che su disco)": ("Logical Size (Instead of On Disk)", "Tamaño lógico (en vez de en disco)", "Taille logique (au lieu de sur le disque)", "Logische Größe (statt auf dem Volume)", "逻辑大小（而不是占用磁盘）", "論理サイズ（ディスク上ではなく）"),
    "Apri i pacchetti": ("Open Packages", "Abrir los paquetes", "Ouvrir les paquets", "Pakete öffnen", "打开包", "パッケージを開く"),
    "Spazio libero, volumi di sistema e spazio nascosto": ("Free Space, System Volumes and Hidden Space", "Espacio libre, volúmenes del sistema y espacio oculto", "Espace libre, volumes système et espace caché", "Freier Speicher, Systemvolumes und versteckter Speicher", "可用空间、系统宗卷和隐藏空间", "空き領域、システムボリューム、隠れた領域"),
    "Schermo intero": ("Enter Full Screen", "Pantalla completa", "Plein écran", "Vollbildmodus", "进入全屏幕", "フルスクリーンにする"),
    "Finestra": ("Window", "Ventana", "Fenêtre", "Fenster", "窗口", "ウインドウ"),
    "Contrai": ("Minimize", "Minimizar", "Placer dans le Dock", "Im Dock ablegen", "最小化", "しまう"),
    "Ridimensiona": ("Zoom", "Zoom", "Réduire/agrandir", "Zoomen", "缩放", "拡大/縮小"),

    # i dischi
    "Che cosa occupa il disco?": ("What’s taking up the disk?", "¿Qué ocupa el disco?", "Qu’est-ce qui occupe le disque ?", "Was belegt das Volume?", "是什么占用了磁盘？", "ディスクを使っているのは何？"),
    "%@ usati di %@ · %@ liberi": ("%@ used of %@ · %@ free", "%@ usados de %@ · %@ libres", "%@ utilisés sur %@ · %@ libres", "%@ von %@ belegt · %@ frei", "已用 %@，共 %@ · 可用 %@", "%2$@ 中 %1$@ 使用 · 空き %3$@"),
    "Si può anche trascinare una cartella sull'icona di %@.": ("You can also drag a folder onto the %@ icon.", "También puedes arrastrar una carpeta al icono de %@.", "Vous pouvez aussi faire glisser un dossier sur l’icône de %@.", "Du kannst auch einen Ordner auf das Symbol von %@ ziehen.", "也可以将文件夹拖到 %@ 图标上。", "%@ のアイコンにフォルダをドラッグすることもできます。"),
}

# il copyright nel pannello Informazioni
COPYRIGHT = {
    "it": "Riscritto in Swift da Riccardo Di Paola (2026) a partire da Disk Inventory X di Tjark Derlien (2003–2022). GPL 3.",
    "en": "Rewritten in Swift by Riccardo Di Paola (2026) from Disk Inventory X by Tjark Derlien (2003–2022). GPL 3.",
    "es": "Reescrito en Swift por Riccardo Di Paola (2026) a partir de Disk Inventory X de Tjark Derlien (2003–2022). GPL 3.",
    "fr": "Réécrit en Swift par Riccardo Di Paola (2026) à partir de Disk Inventory X de Tjark Derlien (2003–2022). GPL 3.",
    "de": "In Swift neu geschrieben von Riccardo Di Paola (2026), nach Disk Inventory X von Tjark Derlien (2003–2022). GPL 3.",
    "zh-Hans": "由 Riccardo Di Paola 以 Swift 重写（2026），基于 Tjark Derlien 的 Disk Inventory X（2003–2022）。GPL 3。",
    "ja": "Tjark Derlien の Disk Inventory X（2003–2022）をもとに、Riccardo Di Paola が Swift で書き直しました（2026）。GPL 3。",
}

QUI = os.path.dirname(os.path.abspath(__file__))
RADICE = os.path.dirname(QUI)


def chiavi_nel_codice():
    keys = []
    for f in sorted(glob.glob(os.path.join(RADICE, "Sources", "**", "*.swift"), recursive=True)):
        s = open(f, encoding="utf-8").read()
        for m in re.finditer(r'\bL\((?:one:\s*)?"((?:[^"\\]|\\.)*)"(?:,\s*other:\s*"((?:[^"\\]|\\.)*)")?', s):
            for k in m.groups():
                if k is not None and k not in keys:
                    keys.append(k)
    return keys


def stringa(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    nel_codice = chiavi_nel_codice()
    mancano = [k for k in nel_codice if k not in T]
    if mancano:
        print("traduzioni mancanti:", *mancano, sep="\n  ")
        sys.exit(1)
    for k, v in T.items():
        assert len(v) == len(LINGUE), k
        # gli stessi segnaposto in ogni lingua (contando anche quelli numerati)
        n = len(re.findall(r"%(?:\d\$)?@", k))
        for lingua, t in zip(LINGUE, v):
            assert len(re.findall(r"%(?:\d\$)?@", t)) == n, (lingua, k, t)
    inutili = [k for k in T if k not in nel_codice]
    if inutili:
        print("nota: tradotte ma non più nel codice:", *inutili, sep="\n  ")

    base = os.path.join(RADICE, "assets", "macos", "Localizations")
    for i, lingua in enumerate(["it"] + LINGUE):
        d = os.path.join(base, lingua + ".lproj")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as out:
            out.write("/* generato da tools/traduzioni.py: non modificare a mano */\n\n")
            for k in nel_codice:
                if lingua == "it":
                    # in italiano la chiave è già la frase, tranne i plurali
                    if "(molti)" not in k:
                        continue
                    t = k.replace(" (molti)", "")
                else:
                    t = T[k][i - 1]
                out.write(f"{stringa(k)} = {stringa(t)};\n")
        with open(os.path.join(d, "InfoPlist.strings"), "w", encoding="utf-8") as out:
            out.write(f'"NSHumanReadableCopyright" = {stringa(COPYRIGHT[lingua])};\n')
    print(f"{len(nel_codice)} frasi in {len(LINGUE) + 1} lingue")


main()
