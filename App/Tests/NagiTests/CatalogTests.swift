import EffectCatalog
import Metal
import NagiCore
import Testing

/// The order effects draw in (M5-PLAN 4: gems over moss), and moss only with the WithMoss trait.
struct CatalogTests {
    /// Within a layer, the renderer keeps the catalog's order: gems draw after moss, the light
    /// under water after komorebi.
    @Test @MainActor func effectsInALayerDrawInCatalogOrder() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let ids = try FrameRenderer(device: device, effects: EffectCatalog.all).effectIDs
        let index = { (id: String) in try #require(ids.firstIndex(of: id)) }
        #if WithMoss
        #expect(try index("moss") < index("gems"))
        #else
        #expect(!ids.contains("moss"))
        #endif
        #expect(try index("komorebi") < index("caustics"))
    }
}
