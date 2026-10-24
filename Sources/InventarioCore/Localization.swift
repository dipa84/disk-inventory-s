import Foundation

/// La traduzione di una frase dell'interfaccia. La chiave è la frase in italiano; le traduzioni
/// stanno in <lingua>.lproj/Localizable.strings dentro l'applicazione. Senza traduzione resta
/// l'italiano.
public func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Come `L`, con gli argomenti al posto di %@ (nell'ordine, o %1$@ %2$@ se una lingua li sposta).
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

/// Singolare o plurale secondo il numero (in francese anche lo zero è singolare).
public func L(one: String, other: String, _ n: Int, _ args: CVarArg...) -> String {
    let french = Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true
    let singular = n == 1 || (french && n == 0)
    return String(format: L(singular ? one : other), locale: Locale.current, arguments: args)
}
