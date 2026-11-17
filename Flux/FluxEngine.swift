import Foundation

nonisolated final class FluxEngine: Sendable {

    private let activeVM = FluxVM()

    func testHypervisor(edition: String = "Windows 11 Pro") {
        activeVM.runTest(edition: edition)
    }

    func requestForceStop() {
        activeVM.requestForceStop()
    }

    func runResetDiskValidation() -> Bool {
        FluxVM().runResetDiskValidation()
    }

    func validateNVMe() -> Bool {
        let vm = FluxVM()
        return vm.validateNVMe()
    }

    func runNVMeBenchmark(targetMB: Int = 100) -> (Double, Double) {
        let vm = FluxVM()
        return vm.runNVMeBenchmark(targetMB: targetMB)
    }
}
