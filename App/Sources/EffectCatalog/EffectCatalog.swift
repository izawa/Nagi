import CausticsEffect
import GemsEffect
import KomorebiEffect
import MossEffect
import RainEffect
import RipplesEffect
import NagiKit

/// Every effect the app ships. The core sorts them by layer; within a layer they draw in this
/// order, later ones over earlier ones (gems over moss, M5-PLAN 4; the light under water over
/// komorebi, M4; ripples under rain, M6).
/// Adding an effect: add its package to App/Package.swift and one line here (SPEC 3.2).
public enum EffectCatalog {
    public static var all: [any Effect.Type] {
        [
            Komorebi.self,
            Caustics.self,
            Ripples.self,
            Rain.self,
            Moss.self,
            Gems.self,
        ]
    }
}
