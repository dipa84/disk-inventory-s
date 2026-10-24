// Disk Inventory S — what is taking up the disk, as a cushion treemap.
// Copyright (C) 2026 Riccardo Di Paola
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY; see the
// GNU General Public License in COPYING for details.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The translation of an interface string. The key is the English string; translations live
/// in <language>.lproj/Localizable.strings inside the app. Without a translation the English
/// stays.
public func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Like `L`, with the arguments in place of %@ (in order, or %1$@ %2$@ if a language reorders them).
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

/// Singular or plural according to the number (in French zero is singular too).
public func L(one: String, other: String, _ n: Int, _ args: CVarArg...) -> String {
    let french = Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true
    let singular = n == 1 || (french && n == 0)
    return String(format: L(singular ? one : other), locale: Locale.current, arguments: args)
}
