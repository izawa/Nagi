import CausticsEffect
import FirefliesEffect
import GemsEffect
import KomorebiEffect
#if WithMoss
import MossEffect
#endif
import RainEffect
import RipplesEffect
import NagiKit

/// Every effect the app ships. The core sorts them by layer; within a layer they draw in this
/// order, later ones over earlier ones (gems over moss, M5-PLAN 4; the light under water over
/// komorebi, M4; fireflies over both, M7; ripples under rain, M6).
/// Adding an effect: add its package to App/Package.swift and one line here (SPEC 3.2).
/// Moss ships only with the WithMoss trait (out of the release until its redesign).
public enum EffectCatalog {
    public static var all: [any Effect.Type] {
        var all: [any Effect.Type] = [Komorebi.self, Caustics.self, Fireflies.self, Ripples.self, Rain.self]
        #if WithMoss
        all.append(Moss.self)
        #endif
        all.append(Gems.self)
        return all
    }
}
