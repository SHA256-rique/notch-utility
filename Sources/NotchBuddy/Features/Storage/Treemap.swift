import Foundation
import CoreGraphics

/// Squarified treemap layout.
///
/// ## Why squarified and not the naive slice-and-dice
/// The simple algorithm alternates horizontal and vertical cuts, which produces
/// correct areas and terrible rectangles: one enormous folder next to forty
/// slivers a pixel wide. Slivers are unreadable and, worse, un-clickable.
///
/// Squarified (Bruls, Huizing & van Wijk, 2000) greedily adds rectangles to the
/// current row while doing so improves the row's *worst aspect ratio*, and
/// starts a new row when it stops improving. The result is rectangles close to
/// square, which are both legible and hittable. It is about forty lines and the
/// whole reason a treemap is worth having.
enum Treemap {

    struct Tile<Item> {
        let item: Item
        let rect: CGRect
    }

    /// Lays `items` out in `bounds`, proportional to `weight`.
    ///
    /// Items are laid out in the order given; callers pass them largest-first,
    /// which is what makes the big rectangles land in the top-left where the eye
    /// starts.
    static func layout<Item>(_ items: [Item],
                             in bounds: CGRect,
                             weight: (Item) -> Double) -> [Tile<Item>] {
        let positive = items.filter { weight($0) > 0 }
        guard !positive.isEmpty, bounds.width > 1, bounds.height > 1 else { return [] }

        let total = positive.reduce(0) { $0 + weight($1) }
        guard total > 0 else { return [] }

        // Work in area units rather than bytes so the arithmetic stays in a
        // range where Double is comfortable: a 200GB folder in bytes is 2e11,
        // and multiplying two of those before dividing overflows into
        // imprecision.
        let scale = Double(bounds.width * bounds.height) / total
        var remaining = positive.map { (item: $0, area: weight($0) * scale) }

        var tiles: [Tile<Item>] = []
        var free = bounds

        while !remaining.isEmpty {
            let shortSide = Double(min(free.width, free.height))
            guard shortSide > 0.5 else { break }

            var row: [(item: Item, area: Double)] = []
            var rowArea: Double = 0
            var bestRatio = Double.greatestFiniteMagnitude

            // Grow the row while the worst aspect ratio keeps improving.
            while let next = remaining.first {
                let candidateArea = rowArea + next.area
                let candidate = row + [next]
                let ratio = worstAspectRatio(candidate.map(\.area),
                                             totalArea: candidateArea,
                                             shortSide: shortSide)
                if row.isEmpty || ratio <= bestRatio {
                    row = candidate
                    rowArea = candidateArea
                    bestRatio = ratio
                    remaining.removeFirst()
                } else {
                    break
                }
            }

            guard !row.isEmpty else { break }
            let horizontal = free.width >= free.height
            let thickness = CGFloat(rowArea / shortSide)

            var offset: CGFloat = 0
            for element in row {
                let length = CGFloat(element.area / max(rowArea, .leastNonzeroMagnitude)) * shortSide
                let rect: CGRect = horizontal
                    ? CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                    : CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                tiles.append(Tile(item: element.item, rect: rect))
                offset += length
            }

            free = horizontal
                ? CGRect(x: free.minX + thickness, y: free.minY,
                         width: max(0, free.width - thickness), height: free.height)
                : CGRect(x: free.minX, y: free.minY + thickness,
                         width: free.width, height: max(0, free.height - thickness))
        }

        return tiles
    }

    /// The worst width-to-height ratio in a candidate row. Lower is squarer;
    /// 1.0 is perfect.
    private static func worstAspectRatio(_ areas: [Double],
                                         totalArea: Double,
                                         shortSide: Double) -> Double {
        guard let smallest = areas.min(), let largest = areas.max(),
              totalArea > 0, smallest > 0 else { return .greatestFiniteMagnitude }
        let side2 = shortSide * shortSide
        let total2 = totalArea * totalArea
        return max(side2 * largest / total2, total2 / (side2 * smallest))
    }
}
