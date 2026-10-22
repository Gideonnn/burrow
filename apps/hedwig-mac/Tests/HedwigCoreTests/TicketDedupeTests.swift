import HedwigCore
import Testing

struct TicketDedupeTests {
    @Test func showsATicketInPdfAndWalletOnceAsItsPass() {
        let keep = TicketDedupe.keep([
            .init(payload: "A", isPass: false),
            .init(payload: "B", isPass: false),
            .init(payload: "A", isPass: true),
            .init(payload: "B", isPass: true),
            .init(payload: nil, isPass: false),
            .init(payload: "C", isPass: false),
            .init(payload: "C", isPass: false),
        ])
        #expect(keep == [false, false, true, true, true, true, false])
    }
}
