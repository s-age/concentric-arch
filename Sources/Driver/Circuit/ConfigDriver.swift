import Foundation
import Kernel
import Contract
import Circuit

/// The *driver* for the `Circuit.Config` port.
///
/// Each symbol maps to one orchestration pipeline (a `package` function in the
/// `Circuit` module), invoked with the kernel handed in at call time.
///
/// Layer-prefixed (`Circuit…`) to avoid colliding with the Infrastructure config
/// driver, since the `Config` port name is shared across both layers.
package struct CircuitConfigDriver {
    package init() {}

    package func wire(into builder: KernelBuilder) {
        builder.register(Contract.Circuit.Config.load) { kernel, payload in
            try await loadConfig(kernel, payload)
        }
        builder.register(Contract.Circuit.Config.save) { kernel, payload in
            try await saveConfig(kernel, payload)
        }
    }
}
