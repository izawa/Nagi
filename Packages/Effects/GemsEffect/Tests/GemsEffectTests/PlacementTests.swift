import CoreGraphics
import NagiKit
import Testing
@testable import GemsEffect

struct PlacementTests {
    /// Too short for a section on its sides (the tests of the top need no side clusters).
    private func window(_ id: UInt32 = 1, width: Double = 368, height: Double = 300, age: Double = 14400) -> WindowInfo {
        WindowInfo(id: id, frame: CGRect(x: -40, y: 100, width: width, height: height),
                   role: .surface, stationarySeconds: age)
    }

    private func snapshot(_ windows: [WindowInfo], areas: [CGRect] = []) -> WindowSnapshot {
        WindowSnapshot(frontToBack: windows, layoutRevision: 1, usableAreas: areas, desktopSeconds: 0)
    }

    @Test func sectionsRespectCornersAndMargins() throws {
        #expect(Placement.clusters(snapshot([window(width: 367.5)])).isEmpty)
        for id: UInt32 in 1...32 {
            // One section on the top, which always has a cluster.
            #expect(Placement.clusters(snapshot([window(id)])).filter { $0.crystals[0].root.y < 200 }.count == 1)
        }
        let wide = window(width: 2400, height: 200)
        let scene = snapshot([wide])
        // The top's clusters (the bottom has some too).
        let clusters = Placement.clusters(scene).filter { $0.crystals[0].root.y < wide.frame.midY }
        #expect(!clusters.isEmpty)
        #expect(Placement.clusters(scene) == Placement.clusters(scene))
        for cluster in clusters {
            let root = try #require(cluster.crystals.first?.root)
            let offset = root.x - (wide.frame.minX + 16 + 72)
            let section = floor(offset / 240)
            #expect(section >= 0)
            #expect((section + 1) * 240 <= wide.frame.width - 32 - 72 - 24)
            // The cluster's root lies in the middle 60 % of its section; the main crystal stands near it.
            #expect((37...203).contains(offset - section * 240))
            #expect(root.y == wide.frame.minY + 1.5)
            // The others stand on the same edge, near the main crystal; one stone per cluster.
            #expect(cluster.crystals.allSatisfy { $0.root.y == root.y && abs($0.root.x - root.x) <= 72 * 0.6 })
            #expect(Set(cluster.crystals.map(\.stone)).count == 1)
        }
    }

    @Test func headroomUsesTheDisplayWithMostOfTheWindow() {
        let areas = [CGRect(x: -800, y: 0, width: 800, height: 800),
                     CGRect(x: 0, y: 30, width: 800, height: 800)]
        var surface = window()
        surface.frame.origin.y = 43.5
        #expect(Placement.clusters(snapshot([surface], areas: areas)).isEmpty)
        // Enough headroom for the window, but the grown cluster would reach above the display.
        surface.frame.origin.y = 44
        #expect(Placement.clusters(snapshot([surface], areas: areas)).isEmpty)
        surface.frame.origin.y = 130
        #expect(Placement.clusters(snapshot([surface], areas: areas)).count == 1)
        surface.role = .occluder
        #expect(Placement.clusters(snapshot([surface], areas: areas)).isEmpty)
    }

    @Test func onlyFrontWindowsCanCoverACluster() throws {
        let surface = window()
        let original = try #require(Placement.clusters(snapshot([surface])).first)
        let bounds = original.bounds
        var front = WindowInfo(id: 2, frame: bounds.insetBy(dx: -20, dy: -20), role: .occluder, stationarySeconds: 0)
        #expect(Placement.clusters(snapshot([front, surface])).isEmpty)
        #expect(Placement.clusters(snapshot([surface, front])) == [original])

        // Covering only the right edge: kept, with the window in front to clip against.
        front.frame.origin.x = bounds.maxX - 3
        let cluster = try #require(Placement.clusters(snapshot([front, surface])).first)
        #expect(cluster.fronts == [front.frame])
        // Covering the root but not every tip: left out (a tip would float over the window).
        front.frame.origin = CGPoint(x: bounds.minX - 1, y: bounds.minY - 1)
        #expect(Placement.clusters(snapshot([front, surface])).isEmpty)
    }

    /// A small panel over a crystal's root takes it away (and its close neighbours), not the cluster.
    @Test func aSmallPanelCoversTheRootUnderIt() throws {
        let surface = window()
        let original = try #require(Placement.clusters(snapshot([surface])).first)
        let root = original.crystals[1].root
        let panel = WindowInfo(id: 9, frame: CGRect(x: root.x - 4, y: root.y - 4, width: 8, height: 8),
                               role: .occluder, stationarySeconds: 0)
        let cluster = try #require(Placement.clusters(snapshot([panel, surface])).first)
        #expect(!cluster.crystals.contains { $0.root == root })
        #expect(cluster.crystals.count < original.crystals.count)
    }

    /// Covering the top's only cluster hides it: no cluster takes its place elsewhere, and the
    /// others keep their roots and stones.
    @Test func aCoveredClusterIsNotReplaced() throws {
        // The least amount, so most windows have only the cluster every top must have.
        var lone = 0
        for id: UInt32 in 1...32 {
            let surface = window(id, width: 2400, height: 200)
            let original = Placement.clusters(snapshot([surface]), amount: 0.3)
            let top = original.filter { $0.crystals[0].root.y < surface.frame.midY }
            let hidden = try #require(top.first)
            if top.count == 1 { lone += 1 }
            let panel = WindowInfo(id: 99, frame: hidden.bounds.insetBy(dx: -2, dy: -2), role: .occluder,
                                   stationarySeconds: 0)
            let covered = Placement.clusters(snapshot([panel, surface]), amount: 0.3)
            func roots(_ clusters: [Cluster]) -> Set<String> {
                Set(clusters.map { "\($0.crystals[0].root) \($0.crystals[0].stone)" })
            }
            #expect(roots(covered).isSubset(of: roots(original)))
            #expect(!roots(covered).contains("\(hidden.crystals[0].root) \(hidden.crystals[0].stone)"))
            // Those clear of the panel are all still there.
            #expect(roots(original.filter { !$0.bounds.intersects(panel.frame) }).isSubset(of: roots(covered)))
        }
        #expect(lone > 0)
    }

    /// A window partly off the display keeps a cluster on its top where one fits.
    @Test func theTopClusterIsOneThatFits() {
        let display = [CGRect(x: 0, y: 0, width: 1600, height: 900)]
        for id: UInt32 in 1...32 {
            var surface = window(id, width: 700)
            // The first top section is off the display, the second wholly on it.
            surface.frame.origin = CGPoint(x: -250, y: 300)
            let top = Placement.clusters(snapshot([surface], areas: display))
                .filter { $0.crystals[0].root.y < surface.frame.midY }
            #expect(!top.isEmpty)
        }
    }

    /// A window across two displays: each cluster lies wholly on the display under its root
    /// (each display bends only its own screen), and both displays get some.
    @Test func noClusterCrossesADisplaySeam() {
        let areas = [CGRect(x: 0, y: 25, width: 1600, height: 875), CGRect(x: 1600, y: 0, width: 1600, height: 900)]
        var sides: Set<Int> = []
        for id: UInt32 in 1...32 {
            let surface = WindowInfo(id: id, frame: CGRect(x: 1000, y: 200, width: 1200, height: 500),
                                     role: .surface, stationarySeconds: 14400)
            for cluster in Placement.clusters(snapshot([surface], areas: areas), amount: Placement.amounts.upperBound) {
                let root = cluster.crystals[0].root
                let under = areas.firstIndex { $0.contains(root) }
                #expect(under.map { areas[$0].contains(cluster.bounds) } == true)
                if let under { sides.insert(under) }
            }
        }
        #expect(sides == [0, 1])
    }

    /// More of the setting only adds clusters, up to its most, where every section of the top of a
    /// clear window holds three, placed at least a fifth of a section apart.
    @Test func moreOnlyAddsUpToACrust() {
        func roots(_ clusters: [Cluster]) -> [CGPoint] { clusters.map { $0.crystals[0].root } }
        for id: UInt32 in 1...16 {
            let surface = WindowInfo(id: id, frame: CGRect(x: 100, y: 100, width: 1400, height: 900),
                                     role: .surface, stationarySeconds: 14400)
            var previous: Set<String> = []
            for amount in stride(from: 0.3, through: Placement.amounts.upperBound, by: 0.1) {
                let now = Set(roots(Placement.clusters(snapshot([surface]), amount: amount)).map { "\($0)" })
                #expect(previous.isSubset(of: now))
                previous = now
            }
            let most = roots(Placement.clusters(snapshot([surface]), amount: Placement.amounts.upperBound))
            let top = most.filter { $0.y == surface.frame.minY + 1.5 }.map(\.x).sorted()
            // Five sections on the top; the first section's start is left bare by the corner.
            #expect(top.count == 3 * 5 - 1)
            // The main crystal stands up to 0.15 of its 72 pt from its cluster's place.
            #expect(zip(top, top.dropFirst()).allSatisfy { $1 - $0 >= 48 - 2 * 72 * 0.15 })
        }
    }

    @Test func growthUsesScaledWindowAgeAndStaggersSideCrystals() throws {
        #expect(Placement.clusters(snapshot([window(age: 599)])).isEmpty)
        #expect(Placement.growth(age: 600) == 0)
        // A small pillar, about a third, by 30 minutes (M5-PLAN 4).
        #expect((0.3...0.36).contains(Placement.growth(age: 1800)))
        #expect(Placement.growth(age: 7200) == 1)
        #expect(Placement.growth(age: .infinity) == 1)
        #expect(Placement.growth(age: -.infinity) == 0)
        #expect(Placement.growth(age: .nan) == 0)

        var missingSides = 0, visibleSides = 0
        for id: UInt32 in 1...32 {
            let halfHour = snapshot([window(id, age: 1800)])
            let young = try #require(Placement.clusters(halfHour).first)
            let oneHour = snapshot([window(id, age: 3600)])
            let twoHours = try #require(Placement.clusters(oneHour, speed: 2).first)
            let mature = try #require(Placement.clusters(oneHour, speed: 4).first)
            #expect(young.crystals.count == 1)
            #expect(young.bounds == mature.bounds)
            #expect(twoHours.crystals.first == mature.crystals.first)
            #expect(twoHours.crystals.dropFirst().allSatisfy { $0.length >= 0.5 && $0.length < $0.fullLength })
            #expect((8...13).contains(mature.crystals.count))
            #expect(mature.crystals.allSatisfy { $0.length == $0.fullLength })
            visibleSides += twoHours.crystals.count - 1
            missingSides += mature.crystals.count - twoHours.crystals.count
        }
        #expect(visibleSides > 0)
        #expect(missingSides > 0)
    }

    /// Clusters grow out of every edge, a few on the sides and the bottom, pointing away from
    /// the window and standing on its edge.
    @Test func everyEdgeGrowsOutward() {
        var seen: Set<Int> = []
        for id: UInt32 in 1...64 {
            let tall = window(id, width: 1200, height: 1200)
            let f = tall.frame
            for cluster in Placement.clusters(snapshot([tall])) {
                let main = cluster.crystals[0]
                let out = CGVector(dx: sin(main.angle), dy: -cos(main.angle))
                if abs(main.root.y - (f.minY + 1.5)) < 1e-9 { seen.insert(0); #expect(out.dy < -0.9) }
                else if abs(main.root.x - (f.maxX - 1.5)) < 1e-9 { seen.insert(1); #expect(out.dx > 0.9) }
                else if abs(main.root.y - (f.maxY - 1.5)) < 1e-9 { seen.insert(2); #expect(out.dy > 0.9) }
                else if abs(main.root.x - (f.minX + 1.5)) < 1e-9 { seen.insert(3); #expect(out.dx < -0.9) }
                else { Issue.record("a cluster off every edge: \(main.root)") }
            }
        }
        #expect(seen == [0, 1, 2, 3])
    }

    @Test func stoneSharesAcrossWindows() {
        var counts: [Stone: Int] = [:]
        for id: UInt32 in 1...1000 {
            for cluster in Placement.clusters(snapshot([window(id)])) {
                for crystal in cluster.crystals { counts[crystal.stone, default: 0] += 1 }
            }
        }
        let total = Double(counts.values.reduce(0, +))
        func share(_ stone: Stone) -> Double { Double(counts[stone, default: 0]) / total }
        for (stone, expected) in Stone.shares {
            #expect(abs(share(stone) - expected) < 0.04)
        }
    }

    /// The deep light stands on the main crystal's axis, the same whatever covers part of the
    /// cluster or however far it has grown, so its images never jump.
    @Test func theDeepLightStaysPut() throws {
        let original = try #require(Placement.clusters(snapshot([window()])).first)
        let main = original.crystals[0]
        let rise = main.fullLength * 0.22
        #expect(abs(original.light.x - (main.root.x + sin(main.angle) * rise)) < 1e-9)
        #expect(abs(original.light.y - (main.root.y - cos(main.angle) * rise)) < 1e-9)
        #expect(abs(original.lightDepth - main.fullLength * 0.13) < 1e-9)
        // A small panel over the main crystal's root takes that crystal away, not its neighbours.
        let panel = WindowInfo(id: 2, frame: CGRect(x: main.root.x - 2, y: main.root.y - 2, width: 4, height: 4),
                               role: .occluder, stationarySeconds: 0)
        let covered = try #require(Placement.clusters(snapshot([panel, window()])).first)
        #expect(!covered.crystals.contains { $0.seed == main.seed } && !covered.crystals.isEmpty)
        #expect(covered.light == original.light && covered.lightDepth == original.lightDepth)
        let young = try #require(Placement.clusters(snapshot([window(age: 2400)])).first)
        #expect(young.light == original.light && young.lightDepth == original.lightDepth)
    }
}

struct LightTests {
    @Test func theDeepLightComesInFrom30To90Seconds() {
        #expect(Gems.deepening(depth: 0) == 0)
        #expect(Gems.deepening(depth: 30) == 0)
        #expect(abs(Gems.deepening(depth: 60) - 0.5) < 1e-9)
        #expect(Gems.deepening(depth: 90) == 1)
        #expect(Gems.deepening(depth: 120) == 1)
        #expect(Gems.deepening(depth: .nan) == 0)
    }

    @Test func theMoonGlintsLessAndACloudTakesTheGlint() {
        var environment = SharedEnvironment()
        environment.sun = CelestialPosition(altitude: 60 * .pi / 180, azimuth: 1)
        #expect(Gems.light(environment).w == 1)
        environment.sunOcclusion = 0.75
        #expect(Gems.light(environment).w == 0.25)
        environment.sunOcclusion = 0
        environment.sun.altitude = -20 * .pi / 180
        environment.moon = CelestialPosition(altitude: 40 * .pi / 180, azimuth: 2)
        environment.moonPhase = 0.5
        #expect(abs(Double(Gems.light(environment).w) - Gems.moonGlint) < 1e-6)
        environment.moonPhase = 0
        #expect(Gems.light(environment).w == 0)
    }
}
