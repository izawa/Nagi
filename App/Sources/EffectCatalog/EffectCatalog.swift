import KomorebiEffect
import MossEffect
import RainEffect
import NagiKit

/// Every effect the app ships, in no particular order (the core sorts by layer).
/// Adding an effect: add its package to App/Package.swift and one line here (SPEC 3.2).
public enum EffectCatalog {
    public static var all: [any Effect.Type] {
        [
            Komorebi.self,
            Rain.self,
            Moss.self,
        ]
    }
}
