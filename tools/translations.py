#!/usr/bin/env python3
# Copyright (C) 2026 Riccardo Di Paola. SPDX-License-Identifier: GPL-3.0-or-later
"""The interface translations: a single table, from English to the other six languages.

Writes assets/macos/Localizations/<language>.lproj/Localizable.strings (and InfoPlist.strings) and
checks that every string passed to L() in the code is translated into every language: if one is
missing it stops, and tools/build-app.sh with it.

Keys are the English strings (the development language). Plurals use two keys, the singular and
the plural (see L(one:other:) in Sources/DiskInventoryCore/Localization.swift).
"""
import glob
import os
import re
import sys

LANGUAGES = ["it", "es", "fr", "de", "zh-Hans", "ja"]

# English string: (Italian, Spanish, French, German, Simplified Chinese, Japanese)
T = {
    "%@ file, %@": ("%@ file, %@", "%@ archivo, %@", "%@ fichier, %@", "%@ Datei, %@", "%@ 个文件，%@", "%@ 個のファイル、%@"),
    "%@ files, %@": ("%@ file, %@", "%@ archivos, %@", "%@ fichiers, %@", "%@ Dateien, %@", "%@ 个文件，%@", "%@ 個のファイル、%@"),
    "read in %@": ("letti in %@", "leídos en %@", "lus en %@", "gelesen in %@", "用时 %@", "読み込み %@"),
    "To read everything, Disk Inventory S needs Full Disk Access (System Settings › Privacy & Security).": ("Per leggere tutto, Disk Inventory S ha bisogno dell'Accesso completo al disco (Impostazioni di Sistema › Privacy e sicurezza).", "Para leerlo todo, Disk Inventory S necesita Acceso total al disco (Ajustes del Sistema › Privacidad y seguridad).", "Pour tout lire, Disk Inventory S a besoin de l’accès complet au disque (Réglages Système › Confidentialité et sécurité).", "Um alles zu lesen, braucht Disk Inventory S den Festplattenvollzugriff (Systemeinstellungen › Datenschutz & Sicherheit).", "要读取全部内容，Disk Inventory S 需要“完全磁盘访问权限”（系统设置 › 隐私与安全性）。", "すべてを読み込むには、Disk Inventory S に「フルディスクアクセス」が必要です（システム設定 › プライバシーとセキュリティ）。"),
    "%@ file": ("%@ file", "%@ archivo", "%@ fichier", "%@ Datei", "%@ 个文件", "%@ 個のファイル"),
    "%@ files": ("%@ file", "%@ archivos", "%@ fichiers", "%@ Dateien", "%@ 个文件", "%@ 個のファイル"),
    "Rereading %@…": ("Rileggo %@…", "Volviendo a leer %@…", "Relecture de %@…", "%@ wird neu gelesen …", "正在重新读取 %@…", "%@ を再読み込み中…"),
    "Reading system folders…": ("Leggo le cartelle di sistema…", "Leyendo las carpetas del sistema…", "Lecture des dossiers système…", "Systemordner werden gelesen …", "正在读取系统文件夹…", "システムフォルダを読み込み中…"),
    "%@ folder not read — Read…": ("%@ cartella non letta — Leggi…", "%@ carpeta no leída — Leer…", "%@ dossier non lu — Lire…", "%@ Ordner nicht gelesen – Lesen …", "%@ 个文件夹未读取 — 读取…", "未読のフォルダ %@ 個 — 読み込む…"),
    "%@ folders not read — Read…": ("%@ cartelle non lette — Leggi…", "%@ carpetas no leídas — Leer…", "%@ dossiers non lus — Lire…", "%@ Ordner nicht gelesen – Lesen …", "%@ 个文件夹未读取 — 读取…", "未読のフォルダ %@ 個 — 読み込む…"),
    "These are system folders an app can’t read. Disk Inventory S reads them with the administrator password, without changing anything.": ("Sono cartelle di sistema che un'app non può leggere. Disk Inventory S le legge con la password da amministratore, senza cambiare niente.", "Son carpetas del sistema que una app no puede leer. Disk Inventory S las lee con la contraseña de administrador, sin cambiar nada.", "Ce sont des dossiers système qu’une app ne peut pas lire. Disk Inventory S les lit avec le mot de passe administrateur, sans rien modifier.", "Das sind Systemordner, die eine App nicht lesen kann. Disk Inventory S liest sie mit dem Administratorpasswort, ohne etwas zu ändern.", "这些是应用无法读取的系统文件夹。Disk Inventory S 会使用管理员密码读取它们，不做任何更改。", "アプリが読み込めないシステムフォルダです。Disk Inventory S は管理者パスワードを使って読み込むだけで、何も変更しません。"),
    "%@ private folder not read…": ("%@ cartella privata non letta…", "%@ carpeta privada no leída…", "%@ dossier privé non lu…", "%@ privater Ordner nicht gelesen …", "%@ 个私有文件夹未读取…", "未読のプライベートフォルダ %@ 個…"),
    "%@ private folders not read…": ("%@ cartelle private non lette…", "%@ carpetas privadas no leídas…", "%@ dossiers privés non lus…", "%@ private Ordner nicht gelesen …", "%@ 个私有文件夹未读取…", "未読のプライベートフォルダ %@ 個…"),
    "Disk Inventory S wants to read the system folders an app can’t open. It only reads them, without changing anything.": ("Disk Inventory S vuole leggere le cartelle di sistema che un'app non può aprire. Le legge soltanto, senza cambiare niente.", "Disk Inventory S quiere leer las carpetas del sistema que una app no puede abrir. Solo las lee, sin cambiar nada.", "Disk Inventory S souhaite lire les dossiers système qu’une app ne peut pas ouvrir. Il les lit seulement, sans rien modifier.", "Disk Inventory S möchte die Systemordner lesen, die eine App nicht öffnen kann. Es liest sie nur und ändert nichts.", "Disk Inventory S 想要读取应用无法打开的系统文件夹。它只读取，不做任何更改。", "Disk Inventory S が、アプリでは開けないシステムフォルダを読み込もうとしています。読み込むだけで、何も変更しません。"),
    "the file system’s indexes and tables": ("gli indici e le tabelle del file system", "los índices y tablas del sistema de archivos", "les index et tables du système de fichiers", "die Indizes und Tabellen des Dateisystems", "文件系统的索引和表", "ファイルシステムのインデックスとテーブル"),
    "the space of the folders that couldn’t be read": ("lo spazio delle cartelle che non si sono lasciate leggere", "el espacio de las carpetas que no se han podido leer", "l’espace des dossiers qui n’ont pas pu être lus", "der Platz der Ordner, die nicht gelesen werden konnten", "无法读取的文件夹所占的空间", "読み込めなかったフォルダの領域"),
    "the folders that couldn’t be read: system ones are read with the button at the bottom of the window (it asks for the password), private ones with Full Disk Access.": ("le cartelle che non si sono lasciate leggere: quelle di sistema si leggono col pulsante in fondo alla finestra (chiede la password), quelle private con l'Accesso completo al disco.", "las carpetas que no se han podido leer: las del sistema se leen con el botón de abajo de la ventana (pide la contraseña), las privadas con Acceso total al disco.", "les dossiers qui n’ont pas pu être lus : les dossiers système se lisent avec le bouton en bas de la fenêtre (il demande le mot de passe), les dossiers privés avec l’accès complet au disque.", "die Ordner, die nicht gelesen werden konnten: Systemordner mit der Taste unten im Fenster (fragt nach dem Passwort), private mit dem Festplattenvollzugriff.", "无法读取的文件夹：系统文件夹可通过窗口底部的按钮读取（需要密码），私有文件夹需要“完全磁盘访问权限”。", "読み込めなかったフォルダ。システムフォルダはウインドウ下部のボタンで読み込めます（パスワードが必要）。プライベートフォルダにはフルディスクアクセスが必要です。"),
    "once everything has been read, what remains: the file system’s indexes and tables.": ("quando si è letto tutto, quello che resta: gli indici e le tabelle del file system.", "cuando se ha leído todo, lo que queda: los índices y tablas del sistema de archivos.", "une fois tout lu, ce qui reste : les index et tables du système de fichiers.", "wenn alles gelesen ist, was übrig bleibt: die Indizes und Tabellen des Dateisystems.", "全部读取后剩下的部分：文件系统的索引和表。", "すべて読み込んだあとに残るもの：ファイルシステムのインデックスとテーブル。"),
    "Folders Not Read": ("Cartelle non lette", "Carpetas no leídas", "Dossiers non lus", "Nicht gelesene Ordner", "未读取的文件夹", "未読のフォルダ"),
    "File System Data": ("Dati del file system", "Datos del sistema de archivos", "Données du système de fichiers", "Dateisystemdaten", "文件系统数据", "ファイルシステムのデータ"),
    "Move “%@” to the Trash?": ("Spostare «%@» nel Cestino?", "¿Trasladar «%@» a la Papelera?", "Placer « %@ » dans la Corbeille ?", "„%@“ in den Papierkorb legen?", "要将“%@”移到废纸篓吗？", "“%@”をゴミ箱に入れますか？"),
    "Move to Trash": ("Sposta nel Cestino", "Trasladar a la Papelera", "Placer dans la Corbeille", "In den Papierkorb legen", "移到废纸篓", "ゴミ箱に入れる"),
    "Cancel": ("Annulla", "Cancelar", "Annuler", "Abbrechen", "取消", "キャンセル"),
    "Don’t ask again": ("Non chiedere più", "No volver a preguntar", "Ne plus demander", "Nicht mehr fragen", "不再询问", "今後確認しない"),
    "Trash": ("Cestino", "Papelera", "Corbeille", "Papierkorb", "废纸篓", "ゴミ箱"),
    "Move to Trash (⌘⌫)": ("Sposta nel Cestino (⌘⌫)", "Trasladar a la Papelera (⌘⌫)", "Placer dans la Corbeille (⌘⌫)", "In den Papierkorb legen (⌘⌫)", "移到废纸篓 (⌘⌫)", "ゴミ箱に入れる (⌘⌫)"),
    "Open": ("Apri", "Abrir", "Ouvrir", "Öffnen", "打开", "開く"),
    "Show in Finder": ("Mostra nel Finder", "Mostrar en el Finder", "Afficher dans le Finder", "Im Finder zeigen", "在访达中显示", "Finderに表示"),
    "Show in Finder (⌘R)": ("Mostra nel Finder (⌘R)", "Mostrar en el Finder (⌘R)", "Afficher dans le Finder (⌘R)", "Im Finder zeigen (⌘R)", "在访达中显示 (⌘R)", "Finderに表示 (⌘R)"),
    "Quick Look": ("Anteprima", "Vista rápida", "Coup d’œil", "Übersicht", "快速查看", "クイックルック"),
    "Go In": ("Entra", "Entrar", "Entrer", "Hineingehen", "进入", "中に入る"),
    "Refresh": ("Aggiorna", "Actualizar", "Actualiser", "Aktualisieren", "刷新", "更新"),
    "Refresh All": ("Aggiorna tutto", "Actualizar todo", "Tout actualiser", "Alles aktualisieren", "全部刷新", "すべて更新"),
    "Copy Path": ("Copia il percorso", "Copiar la ruta", "Copier le chemin", "Pfad kopieren", "拷贝路径", "パスをコピー"),
    "Go Out": ("Esci", "Salir", "Sortir", "Hinausgehen", "退出文件夹", "外に出る"),
    "Out / In": ("Esci / Entra", "Salir / Entrar", "Sortir / Entrer", "Hinaus / Hinein", "退出 / 进入", "外へ / 中へ"),
    "Go out of the folder (⌘[) / Go into the selection (↩)": ("Esci dalla cartella (⌘[) / Entra nella scelta (↩)", "Salir de la carpeta (⌘[) / Entrar en la selección (↩)", "Sortir du dossier (⌘[) / Entrer dans la sélection (↩)", "Ordner verlassen (⌘[) / In die Auswahl gehen (↩)", "退出文件夹 (⌘[) / 进入所选项 (↩)", "フォルダの外へ (⌘[) / 選択項目の中へ (↩)"),
    "Folder Shown": ("Cartella mostrata", "Carpeta mostrada", "Dossier affiché", "Angezeigter Ordner", "显示的文件夹", "表示中のフォルダ"),
    "Reread the selected folder from disk (⇧⌘R)": ("Rileggi dal disco la cartella scelta (⇧⌘R)", "Volver a leer del disco la carpeta seleccionada (⇧⌘R)", "Relire depuis le disque le dossier sélectionné (⇧⌘R)", "Ausgewählten Ordner neu vom Volume lesen (⇧⌘R)", "从磁盘重新读取所选文件夹 (⇧⌘R)", "選択したフォルダをディスクから再読み込み (⇧⌘R)"),
    "Reading %@": ("Leggo %@", "Leyendo %@", "Lecture de %@", "%@ wird gelesen", "正在读取 %@", "%@ を読み込み中"),
    "%@ files in %@ folders · %@": ("%@ file in %@ cartelle · %@", "%@ archivos en %@ carpetas · %@", "%@ fichiers dans %@ dossiers · %@", "%@ Dateien in %@ Ordnern · %@", "%@ 个文件，%@ 个文件夹 · %@", "%@ 個のファイル、%@ 個のフォルダ · %@"),
    "Cancelling…": ("Annullo…", "Cancelando…", "Annulation…", "Wird abgebrochen …", "正在取消…", "キャンセル中…"),
    "Name": ("Nome", "Nombre", "Nom", "Name", "名称", "名前"),
    "Size": ("Dimensione", "Tamaño", "Taille", "Größe", "大小", "サイズ"),
    "Kind": ("Tipo", "Tipo", "Type", "Art", "种类", "種類"),
    "Files": ("File", "Archivos", "Fichiers", "Dateien", "文件", "ファイル"),
    "the space still available": ("lo spazio ancora disponibile", "el espacio aún disponible", "l’espace encore disponible", "der noch verfügbare Platz", "仍然可用的空间", "まだ使える領域"),
    "virtual memory, Preboot, Recovery, macOS updates": ("memoria virtuale, Preboot, Recovery, aggiornamenti di macOS", "memoria virtual, Preboot, Recovery, actualizaciones de macOS", "mémoire virtuelle, Preboot, Recovery, mises à jour de macOS", "virtueller Speicher, Preboot, Recovery, macOS-Updates", "虚拟内存、Preboot、Recovery、macOS 更新", "仮想メモリ、Preboot、Recovery、macOSアップデート"),
    "unreadable: needs Full Disk Access": ("non leggibile: serve l'Accesso completo al disco", "no legible: necesita Acceso total al disco", "illisible : nécessite l’accès complet au disque", "nicht lesbar: Festplattenvollzugriff nötig", "无法读取：需要“完全磁盘访问权限”", "読み取れません：フルディスクアクセスが必要です"),
    "another volume: not counted here": ("un altro volume: non è contato qui", "otro volumen: no se cuenta aquí", "un autre volume : non compté ici", "ein anderes Volume: hier nicht gezählt", "另一个宗卷：不在此处计算", "別のボリューム：ここでは数えません"),
    "the same folder seen from / (firmlink): counted there": ("è la stessa cartella che si vede da / (firmlink): contata là", "es la misma carpeta que se ve desde / (firmlink): contada allí", "c’est le même dossier vu depuis / (firmlink) : compté là-bas", "derselbe Ordner wie unter / (Firmlink): dort gezählt", "与从 / 看到的是同一个文件夹（固定链接）：在那里计算", "/ から見えるのと同じフォルダ（ファームリンク）：そちらで数えます"),
    "skipped (Settings › Scan)": ("saltata (Impostazioni › Scansione)", "omitida (Ajustes › Análisis)", "ignoré (Réglages › Analyse)", "übersprungen (Einstellungen › Scan)", "已跳过（设置 › 扫描）", "スキップ（設定 › スキャン）"),
    "another name of a file already counted elsewhere": ("un altro nome di un file già contato altrove", "otro nombre de un archivo ya contado en otro lugar", "un autre nom d’un fichier déjà compté ailleurs", "ein weiterer Name einer bereits gezählten Datei", "已在别处计算的文件的另一个名称", "ほかの場所で数えたファイルの別名"),
    "a clone: only its own data counts": ("un clone: conta solo quello che ha di suo", "un clon: solo cuenta lo que tiene de propio", "un clone : seul ce qui lui est propre compte", "ein Klon: zählt nur seine eigenen Daten", "克隆：只计算其独有的数据", "クローン：独自のデータだけを数えます"),
    "Free Space": ("Spazio libero", "Espacio libre", "Espace libre", "Freier Speicher", "可用空间", "空き領域"),
    "System Volumes": ("Volumi di sistema", "Volúmenes del sistema", "Volumes système", "Systemvolumes", "系统宗卷", "システムボリューム"),
    ".%@ File": ("File .%@", "Archivo .%@", "Fichier .%@", ".%@-Datei", ".%@ 文件", ".%@ ファイル"),
    "Settings": ("Impostazioni", "Ajustes", "Réglages", "Einstellungen", "设置", "設定"),
    "General": ("Generale", "General", "Général", "Allgemein", "通用", "一般"),
    "Map": ("Mappa", "Mapa", "Carte", "Karte", "图", "マップ"),
    "Scan": ("Scansione", "Análisis", "Analyse", "Scan", "扫描", "スキャン"),
    "Space": ("Spazio", "Espacio", "Espace", "Speicher", "空间", "領域"),
    "On disk (what deleting frees)": ("Su disco (quello che si libera cancellando)", "En disco (lo que se libera al borrar)", "Sur le disque (ce que libère la suppression)", "Auf dem Volume (was Löschen freigibt)", "占用磁盘（删除后释放的空间）", "ディスク上（削除すると空く量）"),
    "Logical (the length of the content)": ("Logica (la lunghezza del contenuto)", "Lógico (la longitud del contenido)", "Logique (la longueur du contenu)", "Logisch (die Länge des Inhalts)", "逻辑大小（内容的长度）", "論理サイズ（内容の長さ）"),
    "For new windows; in an open window, change it from the View menu.": ("Per le finestre nuove; in una finestra aperta si cambia dal menu Vista.", "Para las ventanas nuevas; en una ventana abierta se cambia desde el menú Visualización.", "Pour les nouvelles fenêtres ; dans une fenêtre ouverte, changez-le dans le menu Présentation.", "Für neue Fenster; in einem offenen Fenster im Menü „Darstellung“ ändern.", "用于新窗口；在打开的窗口中可从“显示”菜单更改。", "新しいウインドウ用。開いているウインドウでは「表示」メニューで変更します。"),
    "Units": ("Unità", "Unidades", "Unités", "Einheiten", "单位", "単位"),
    "Decimal: 1 GB = 1000 MB, like the Finder": ("Decimali: 1 GB = 1000 MB, come il Finder", "Decimales: 1 GB = 1000 MB, como el Finder", "Décimales : 1 Go = 1000 Mo, comme le Finder", "Dezimal: 1 GB = 1000 MB, wie der Finder", "十进制：1 GB = 1000 MB，与访达一致", "10進：1 GB = 1000 MB（Finderと同じ）"),
    "Binary: 1 GiB = 1024 MiB": ("Binarie: 1 GiB = 1024 MiB", "Binarias: 1 GiB = 1024 MiB", "Binaires : 1 Gio = 1024 Mio", "Binär: 1 GiB = 1024 MiB", "二进制：1 GiB = 1024 MiB", "2進：1 GiB = 1024 MiB"),
    "Ask before moving to the Trash": ("Chiedi conferma prima di spostare nel Cestino", "Preguntar antes de trasladar a la Papelera", "Demander avant de placer dans la Corbeille", "Vor dem Bewegen in den Papierkorb fragen", "移到废纸篓前询问", "ゴミ箱に入れる前に確認する"),
    "At launch": ("All'avvio", "Al abrir", "Au démarrage", "Beim Start", "启动时", "起動時"),
    "The disks window": ("La finestra dei dischi", "La ventana de los discos", "La fenêtre des disques", "Das Fenster mit den Volumes", "磁盘窗口", "ディスクのウインドウ"),
    "The last folder read": ("L'ultima cartella letta", "La última carpeta leída", "Le dernier dossier lu", "Den zuletzt gelesenen Ordner", "上次读取的文件夹", "最後に読み込んだフォルダ"),
    "Nothing": ("Niente", "Nada", "Rien", "Nichts", "无", "何もしない"),
    "Language": ("Lingua", "Idioma", "Langue", "Sprache", "语言", "言語"),
    "The language changes at the next launch.": ("La lingua cambia al prossimo avvio.", "El idioma cambia la próxima vez que se abra.", "La langue change au prochain démarrage.", "Die Sprache ändert sich beim nächsten Start.", "语言将在下次启动时更改。", "言語は次回の起動時に変わります。"),
    "Relaunch Now": ("Riavvia ora", "Reabrir ahora", "Relancer maintenant", "Jetzt neu starten", "立即重新启动", "今すぐ再起動"),
    "Same as the system": ("Come il sistema", "Como el sistema", "Comme le système", "Wie das System", "跟随系统", "システムと同じ"),
    "Cushion relief": ("Rilievo dei cuscini", "Relieve de los cojines", "Relief des coussins", "Relief der Kissen", "垫面起伏", "クッションの起伏"),
    "flat": ("piatti", "planos", "plats", "flach", "平", "平ら"),
    "high": ("alti", "altos", "hauts", "hoch", "高", "高い"),
    "Light in the shadows": ("Luce nelle ombre", "Luz en las sombras", "Lumière dans les ombres", "Licht in den Schatten", "阴影亮度", "影の明るさ"),
    "dark": ("scure", "oscuras", "sombres", "dunkel", "暗", "暗い"),
    "light": ("chiare", "claras", "claires", "hell", "亮", "明るい"),
    "A dark line between files": ("Una riga scura fra un file e l'altro", "Una línea oscura entre un archivo y otro", "Une ligne sombre entre les fichiers", "Eine dunkle Linie zwischen den Dateien", "文件之间显示深色分隔线", "ファイルの間に暗い線"),
    "Spotlight on the folder under the pointer (hold ⌘ for the one above)": ("Riflettore sulla cartella sotto il puntatore (con ⌘ quella sopra)", "Foco en la carpeta bajo el puntero (con ⌘, la de arriba)", "Projecteur sur le dossier sous le pointeur (avec ⌘, celui du dessus)", "Spotlight auf den Ordner unter dem Zeiger (mit ⌘ der darüber)", "聚光指针下的文件夹（按住 ⌘ 显示上一级）", "ポインタの下のフォルダを強調（⌘ を押すと1つ上）"),
    "Colors": ("Colori", "Colores", "Couleurs", "Farben", "颜色", "色"),
    "Like the original": ("Come l'originale", "Como el original", "Comme l’original", "Wie das Original", "与原版相同", "オリジナルと同じ"),
    "Vivid": ("Accesi", "Vivos", "Vifs", "Kräftig", "鲜艳", "鮮やか"),
    "Soft pastel": ("Pastello tenui", "Pastel suaves", "Pastels doux", "Sanfte Pastelltöne", "柔和粉彩", "淡いパステル"),
    "A frame on the file under the pointer": ("Un bordo sul file sotto il puntatore", "Un borde en el archivo bajo el puntero", "Un cadre sur le fichier sous le pointeur", "Ein Rahmen um die Datei unter dem Zeiger", "为指针下的文件加边框", "ポインタの下のファイルに枠"),
    "Colored kinds": ("Tipi colorati", "Tipos con color", "Types en couleur", "Farbige Arten", "彩色种类", "色付きの種類"),
    "The 12 largest (like the original)": ("I 12 più grandi (come l'originale)", "Los 12 más grandes (como el original)", "Les 12 plus grands (comme l’original)", "Die 12 größten (wie das Original)", "最大的 12 种（与原版相同）", "大きい順に12種類（オリジナルと同じ）"),
    "The 24 largest": ("I 24 più grandi", "Los 24 más grandes", "Les 24 plus grands", "Die 24 größten", "最大的 24 种", "大きい順に24種類"),
    "The other kinds are gray.": ("Gli altri tipi sono grigi.", "Los demás tipos son grises.", "Les autres types sont gris.", "Die anderen Arten sind grau.", "其他种类显示为灰色。", "ほかの種類はグレーです。"),
    "Like the Original": ("Come l'originale", "Como el original", "Comme l’original", "Wie das Original", "恢复原版设置", "オリジナルと同じにする"),
    "Count APFS clones and hard links only once": ("Conta una volta sola i cloni di APFS e i collegamenti fissi", "Contar una sola vez los clones de APFS y los enlaces físicos", "Compter une seule fois les clones APFS et les liens physiques", "APFS-Klone und harte Links nur einmal zählen", "APFS 克隆和硬链接只计算一次", "APFSのクローンとハードリンクは1回だけ数える"),
    "Like du. The Finder and Disk Inventory X count them every time, and a disk can look fuller than it is.": ("Come du. Il Finder e Disk Inventory X li contano ogni volta, e un disco può sembrare più pieno di quanto sia.", "Como du. El Finder y Disk Inventory X los cuentan cada vez, y un disco puede parecer más lleno de lo que está.", "Comme du. Le Finder et Disk Inventory X les comptent à chaque fois, et un disque peut sembler plus plein qu’il ne l’est.", "Wie du. Der Finder und Disk Inventory X zählen sie jedes Mal, und ein Volume kann voller wirken, als es ist.", "与 du 相同。访达和 Disk Inventory X 每次都会计算它们，磁盘可能看起来比实际更满。", "duと同じです。FinderとDisk Inventory Xは毎回数えるため、ディスクが実際より満杯に見えることがあります。"),
    "Go into other volumes (external disks) inside the folder": ("Entra negli altri volumi (dischi esterni) dentro la cartella", "Entrar en otros volúmenes (discos externos) dentro de la carpeta", "Entrer dans les autres volumes (disques externes) du dossier", "Andere Volumes (externe Festplatten) im Ordner einbeziehen", "进入文件夹中的其他宗卷（外置磁盘）", "フォルダ内のほかのボリューム（外部ディスク）にも入る"),
    "Open packages (apps, Photos libraries…)": ("Apri i pacchetti (applicazioni, librerie di Foto…)", "Abrir los paquetes (apps, fototecas…)", "Ouvrir les paquets (apps, photothèques…)", "Pakete öffnen (Apps, Fotos-Mediatheken …)", "打开包（应用、照片图库…）", "パッケージを開く（アプリ、写真ライブラリ…）"),
    "Folders to skip": ("Cartelle da saltare", "Carpetas que omitir", "Dossiers à ignorer", "Zu überspringende Ordner", "要跳过的文件夹", "スキップするフォルダ"),
    "Names separated by commas. They stay in the map as empty folders.": ("Nomi separati da virgole. Restano nella mappa come cartelle vuote.", "Nombres separados por comas. Quedan en el mapa como carpetas vacías.", "Noms séparés par des virgules. Ils restent dans la carte comme des dossiers vides.", "Namen durch Kommas getrennt. Sie bleiben als leere Ordner in der Karte.", "名称以逗号分隔。它们在图中显示为空文件夹。", "名前をカンマで区切ります。マップには空のフォルダとして残ります。"),
    "These choices apply from the next scan.": ("Queste scelte valgono dalla prossima lettura.", "Estas opciones se aplican a partir de la próxima lectura.", "Ces choix s’appliquent à partir de la prochaine lecture.", "Diese Einstellungen gelten ab dem nächsten Lesen.", "这些选项从下次读取开始生效。", "これらの設定は次回の読み込みから有効です。"),
    "When reading a whole disk, also show the space that isn’t in files": ("Quando leggo un disco intero, mostra anche lo spazio che non è nei file", "Al leer un disco entero, mostrar también el espacio que no está en archivos", "Lors de la lecture d’un disque entier, afficher aussi l’espace hors fichiers", "Beim Lesen eines ganzen Volumes auch den Speicher außerhalb von Dateien zeigen", "读取整个磁盘时，也显示不在文件中的空间", "ディスク全体を読み込むとき、ファイル以外の領域も表示する"),
    "the space still available.": ("lo spazio ancora disponibile.", "el espacio aún disponible.", "l’espace encore disponible.", "der noch verfügbare Platz.", "仍然可用的空间。", "まだ使える領域。"),
    "the disk’s other volumes: virtual memory, Preboot, Recovery, macOS updates.": ("gli altri volumi dello stesso disco: memoria virtuale, Preboot, Recovery, aggiornamenti di macOS.", "los otros volúmenes del mismo disco: memoria virtual, Preboot, Recovery, actualizaciones de macOS.", "les autres volumes du même disque : mémoire virtuelle, Preboot, Recovery, mises à jour de macOS.", "die anderen Volumes derselben Festplatte: virtueller Speicher, Preboot, Recovery, macOS-Updates.", "同一磁盘上的其他宗卷：虚拟内存、Preboot、Recovery、macOS 更新。", "同じディスクのほかのボリューム：仮想メモリ、Preboot、Recovery、macOSアップデート。"),
    "Count purgeable space as free too, like the Finder": ("Conta come libero anche lo spazio eliminabile, come il Finder", "Contar también como libre el espacio purgable, como el Finder", "Compter aussi l’espace purgeable comme libre, comme le Finder", "Auch löschbaren Speicher als frei zählen, wie der Finder", "将可清除空间也算作可用，与访达一致", "パージ可能な領域も空きとして数える（Finderと同じ）"),
    "The system frees purgeable space (caches, local iCloud copies) by itself when needed.": ("Lo spazio eliminabile (cache, copie locali di iCloud) il sistema lo libera da sé quando serve.", "El sistema libera por sí mismo el espacio purgable (cachés, copias locales de iCloud) cuando hace falta.", "Le système libère lui-même l’espace purgeable (caches, copies locales iCloud) quand il le faut.", "Das System gibt löschbaren Speicher (Caches, lokale iCloud-Kopien) bei Bedarf selbst frei.", "系统会在需要时自行释放可清除空间（缓存、iCloud 本地副本）。", "パージ可能な領域（キャッシュ、iCloudのローカルコピー）は、必要なときにシステムが自動で解放します。"),
    "Read": ("Leggi", "Leer", "Lire", "Lesen", "读取", "読み込む"),
    "Choose the folder or disk to examine": ("Scegli la cartella o il disco da esaminare", "Elige la carpeta o el disco que examinar", "Choisissez le dossier ou le disque à examiner", "Wähle den Ordner oder das Volume", "选择要检查的文件夹或磁盘", "調べるフォルダまたはディスクを選択してください"),
    "About %@": ("Informazioni su %@", "Acerca de %@", "À propos de %@", "Über %@", "关于%@", "%@について"),
    "Settings…": ("Impostazioni…", "Ajustes…", "Réglages…", "Einstellungen …", "设置…", "設定…"),
    "Hide %@": ("Nascondi %@", "Ocultar %@", "Masquer %@", "%@ ausblenden", "隐藏%@", "%@を非表示"),
    "Hide Others": ("Nascondi altre", "Ocultar otros", "Masquer les autres", "Andere ausblenden", "隐藏其他", "ほかを非表示"),
    "Show All": ("Mostra tutte", "Mostrar todo", "Tout afficher", "Alle einblenden", "全部显示", "すべてを表示"),
    "Quit %@": ("Esci da %@", "Salir de %@", "Quitter %@", "%@ beenden", "退出%@", "%@を終了"),
    "File": ("Archivio", "Archivo", "Fichier", "Ablage", "文件", "ファイル"),
    "Read a Folder…": ("Leggi una cartella…", "Leer una carpeta…", "Lire un dossier…", "Ordner lesen …", "读取文件夹…", "フォルダを読み込む…"),
    "Disks": ("Dischi", "Discos", "Disques", "Volumes", "磁盘", "ディスク"),
    "Close": ("Chiudi", "Cerrar", "Fermer", "Schließen", "关闭", "閉じる"),
    "Edit": ("Modifica", "Edición", "Édition", "Bearbeiten", "编辑", "編集"),
    "Item": ("Scelta", "Elemento", "Élément", "Objekt", "项目", "項目"),
    "Select Enclosing Folder": ("Scegli la cartella che la contiene", "Seleccionar la carpeta contenedora", "Sélectionner le dossier parent", "Übergeordneten Ordner auswählen", "选择所在文件夹", "上のフォルダを選択"),
    "Select Largest Item Inside": ("Scegli la voce più grande dentro", "Seleccionar el elemento más grande de dentro", "Sélectionner le plus grand élément à l’intérieur", "Größtes Objekt darin auswählen", "选择其中最大的项目", "中で一番大きい項目を選択"),
    "View": ("Vista", "Visualización", "Présentation", "Darstellung", "显示", "表示"),
    "Go Into Selection": ("Entra nella scelta", "Entrar en la selección", "Entrer dans la sélection", "In die Auswahl gehen", "进入所选项", "選択項目の中へ"),
    "Go Out of Folder": ("Esci dalla cartella", "Salir de la carpeta", "Sortir du dossier", "Ordner verlassen", "退出文件夹", "フォルダの外へ"),
    "Go Back In": ("Torna dentro", "Volver a entrar", "Revenir dedans", "Wieder hineingehen", "返回内部", "もう一度中へ"),
    "Whole Folder": ("Tutta la cartella", "Toda la carpeta", "Dossier entier", "Ganzer Ordner", "整个文件夹", "フォルダ全体"),
    "Logical Size (Instead of On Disk)": ("Dimensione logica (invece che su disco)", "Tamaño lógico (en vez de en disco)", "Taille logique (au lieu de sur le disque)", "Logische Größe (statt auf dem Volume)", "逻辑大小（而不是占用磁盘）", "論理サイズ（ディスク上ではなく）"),
    "Open Packages": ("Apri i pacchetti", "Abrir los paquetes", "Ouvrir les paquets", "Pakete öffnen", "打开包", "パッケージを開く"),
    "Free Space, System Volumes and Hidden Space": ("Spazio libero, volumi di sistema e spazio nascosto", "Espacio libre, volúmenes del sistema y espacio oculto", "Espace libre, volumes système et espace caché", "Freier Speicher, Systemvolumes und versteckter Speicher", "可用空间、系统宗卷和隐藏空间", "空き領域、システムボリューム、隠れた領域"),
    "Enter Full Screen": ("Schermo intero", "Pantalla completa", "Plein écran", "Vollbildmodus", "进入全屏幕", "フルスクリーンにする"),
    "Window": ("Finestra", "Ventana", "Fenêtre", "Fenster", "窗口", "ウインドウ"),
    "Minimize": ("Contrai", "Minimizar", "Placer dans le Dock", "Im Dock ablegen", "最小化", "しまう"),
    "Zoom": ("Ridimensiona", "Zoom", "Réduire/agrandir", "Zoomen", "缩放", "拡大/縮小"),
    "What’s taking up the disk?": ("Che cosa occupa il disco?", "¿Qué ocupa el disco?", "Qu’est-ce qui occupe le disque ?", "Was belegt das Volume?", "是什么占用了磁盘？", "ディスクを使っているのは何？"),
    "%@ used of %@ · %@ free": ("%@ usati di %@ · %@ liberi", "%@ usados de %@ · %@ libres", "%@ utilisés sur %@ · %@ libres", "%@ von %@ belegt · %@ frei", "已用 %@，共 %@ · 可用 %@", "%2$@ 中 %1$@ 使用 · 空き %3$@"),
    "You can also drag a folder onto the %@ icon.": ("Si può anche trascinare una cartella sull'icona di %@.", "También puedes arrastrar una carpeta al icono de %@.", "Vous pouvez aussi faire glisser un dossier sur l’icône de %@.", "Du kannst auch einen Ordner auf das Symbol von %@ ziehen.", "也可以将文件夹拖到 %@ 图标上。", "%@ のアイコンにフォルダをドラッグすることもできます。"),
}

# the copyright line in the About panel
COPYRIGHT = {
    "it": "Riscritto in Swift da Riccardo Di Paola (2026) a partire da Disk Inventory X di Tjark Derlien (2003–2022). GPL 3.",
    "en": "Rewritten in Swift by Riccardo Di Paola (2026) from Disk Inventory X by Tjark Derlien (2003–2022). GPL 3.",
    "es": "Reescrito en Swift por Riccardo Di Paola (2026) a partir de Disk Inventory X de Tjark Derlien (2003–2022). GPL 3.",
    "fr": "Réécrit en Swift par Riccardo Di Paola (2026) à partir de Disk Inventory X de Tjark Derlien (2003–2022). GPL 3.",
    "de": "In Swift neu geschrieben von Riccardo Di Paola (2026), nach Disk Inventory X von Tjark Derlien (2003–2022). GPL 3.",
    "zh-Hans": "由 Riccardo Di Paola 以 Swift 重写（2026），基于 Tjark Derlien 的 Disk Inventory X（2003–2022）。GPL 3。",
    "ja": "Tjark Derlien の Disk Inventory X（2003–2022）をもとに、Riccardo Di Paola が Swift で書き直しました（2026）。GPL 3。",
}

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def keys_in_code():
    keys = []
    for f in sorted(glob.glob(os.path.join(ROOT, "Sources", "**", "*.swift"), recursive=True)):
        s = open(f, encoding="utf-8").read()
        for m in re.finditer(r'\bL\((?:one:\s*)?"((?:[^"\\]|\\.)*)"(?:,\s*other:\s*"((?:[^"\\]|\\.)*)")?', s):
            for k in m.groups():
                if k is not None:
                    k = k.replace('\\"', '"').replace("\\\\", "\\")
                    if k not in keys:
                        keys.append(k)
    return keys


def literal(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    in_code = keys_in_code()
    missing = [k for k in in_code if k not in T]
    if missing:
        print("missing translations:", *missing, sep="\n  ")
        sys.exit(1)
    for k, v in T.items():
        assert len(v) == len(LANGUAGES), k
        # the same placeholders in every language (numbered ones included)
        n = len(re.findall(r"%(?:\d\$)?@", k))
        for language, t in zip(LANGUAGES, v):
            assert len(re.findall(r"%(?:\d\$)?@", t)) == n, (language, k, t)
    unused = [k for k in T if k not in in_code]
    if unused:
        print("note: translated but no longer in the code:", *unused, sep="\n  ")

    base = os.path.join(ROOT, "assets", "macos", "Localizations")
    for i, language in enumerate(["en"] + LANGUAGES):
        d = os.path.join(base, language + ".lproj")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as out:
            out.write("/* generated by tools/translations.py: do not edit */\n\n")
            if language != "en":
                for k in in_code:
                    out.write(f"{literal(k)} = {literal(T[k][i - 1])};\n")
        with open(os.path.join(d, "InfoPlist.strings"), "w", encoding="utf-8") as out:
            out.write(f'"NSHumanReadableCopyright" = {literal(COPYRIGHT[language])};\n')
    print(f"{len(in_code)} strings in {len(LANGUAGES) + 1} languages")


main()
