import CoreGraphics
import HedwigCore
import Testing

struct PictureFrameTests {
    private let image = CGSize(width: 2000, height: 1000)
    private let box = CGSize(width: 600, height: 200)

    @Test func centredFillsTheBoxWithoutEmptyEdges() {
        let (size, origin) = PictureFrame.centred.layout(image: image, box: box)
        #expect(size == CGSize(width: 600, height: 300))
        #expect(origin == CGPoint(x: 0, y: -50))
    }

    @Test func aDragMovesThePictureUntilAnEdge() {
        let down = PictureFrame.centred.dragged(by: CGSize(width: 0, height: 30), image: image, box: box)
        #expect(down.layout(image: image, box: box).origin == CGPoint(x: 0, y: -20))
        let tooFar = PictureFrame.centred.dragged(by: CGSize(width: 400, height: 400), image: image, box: box)
        #expect(tooFar.layout(image: image, box: box).origin == CGPoint(x: 0, y: 0))
    }

    @Test func zoomingKeepsTheMiddleInTheMiddle() {
        let zoomed = PictureFrame(x: 0.6, y: 0.5, zoom: 1).zoomed(to: 2, image: image, box: box)
        #expect(zoomed.zoom == 2)
        #expect(zoomed.x == 0.5)
        let (size, origin) = zoomed.layout(image: image, box: box)
        #expect(size == CGSize(width: 1200, height: 600))
        #expect(origin.x == -300)
        #expect(PictureFrame.centred.zoomed(to: 9, image: image, box: box).zoom == 4)
    }
}
