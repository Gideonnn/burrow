import BurrowUI
import Testing

// #expect cannot call a mutating method itself.
private func release(_ state: inout PullToRefreshState, _ interacting: Bool) -> Bool {
    state.phase(interacting: interacting)
}

struct PullToRefreshTests {
    @Test func aPullPastTheThresholdRefreshesWhenLetGo() {
        var state = PullToRefreshState()
        #expect(!release(&state, true))
        state.scrolled(pull: PullToRefreshState.threshold + 10)
        #expect(state.isPulling)
        #expect(release(&state, false))
        #expect(state.refreshing)
        state.finished()
        #expect(!state.refreshing)
    }

    @Test func aShortPullDoesNothing() {
        var state = PullToRefreshState()
        _ = state.phase(interacting: true)
        state.scrolled(pull: PullToRefreshState.threshold / 2)
        #expect(!release(&state, false))
    }

    @Test func pullingBackBeforeLettingGoCancels() {
        var state = PullToRefreshState()
        _ = state.phase(interacting: true)
        state.scrolled(pull: PullToRefreshState.threshold + 10)
        state.scrolled(pull: 10)
        #expect(!release(&state, false))
    }

    // The bounce back after letting go passes the threshold again, without fingers.
    @Test func theBounceAfterwardsDoesNotRefreshAgain() {
        var state = PullToRefreshState()
        _ = state.phase(interacting: true)
        state.scrolled(pull: PullToRefreshState.threshold + 10)
        #expect(release(&state, false))
        state.scrolled(pull: PullToRefreshState.threshold + 5)
        #expect(!release(&state, false))
        _ = state.phase(interacting: true)
        state.scrolled(pull: PullToRefreshState.threshold + 10)
        #expect(!release(&state, false))
    }
}
