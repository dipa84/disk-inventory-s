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
