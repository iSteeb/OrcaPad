import SwiftUI

/// Placeholder for the connected-printer web UI (desktop "device" panel
/// parity: effectively the printer's own URL). Implemented in a later gate.
struct DeviceTabView: View {
    var body: some View {
        ContentUnavailableView(
            "Device",
            systemImage: "printer",
            description: Text(
                "Printer connection lands in a later phase — this tab will " +
                    "show the connected printer's web interface."
            )
        )
    }
}
