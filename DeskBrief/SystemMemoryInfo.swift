import Foundation
import Metal

enum SystemMemoryInfo {
    static var totalGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    static var currentAvailableBytes: Int? {
        let vmBytes = vmAvailableBytes ?? 0
        guard let device = MTLCreateSystemDefaultDevice() else {
            return vmBytes
        }
        let metalRemaining = Int64(device.recommendedMaxWorkingSetSize) - Int64(device.currentAllocatedSize)
        let usable = min(vmBytes, Int(metalRemaining))
        return max(usable, 0)
    }

    static var currentAvailableGB: Double? {
        guard let bytes = currentAvailableBytes else { return nil }
        return Double(bytes) / 1_073_741_824
    }

    static func isAboveThreshold(thresholdGB: Double) -> Bool {
        guard let bytes = currentAvailableBytes else {
            let vmBytes = vmAvailableBytes ?? 0
            return Double(vmBytes) / 1_073_741_824 > thresholdGB
        }
        return Double(bytes) / 1_073_741_824 > thresholdGB
    }

    private static var vmAvailableBytes: Int? {
        let count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStat = vm_statistics64_data_t()
        var size = count
        let result = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let availablePages = vmStat.free_count + vmStat.inactive_count + vmStat.speculative_count
        let pageSize = Int(vm_kernel_page_size)
        return Int(availablePages) * pageSize
    }
}
