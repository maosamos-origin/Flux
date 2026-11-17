import SwiftUI

struct ContentView: View {

    // The app owns this object for the entire scene lifetime.  Windows only
    // observe it; they must not create an independent lifecycle observer.
    @EnvironmentObject private var session: FluxSessionController
    @ObservedObject private var framebuffer = FluxFramebuffer.shared
    @ObservedObject private var displayManager = FluxDisplayManager.shared
    @State private var showingConfigureSheet = false
    @State private var showingForceStopAlert = false
    @AppStorage("flux.showFPSTelemetry") private var showFPSTelemetry = true

    var body: some View {
        Group {
            if framebuffer.isConfigured {
                FluxDisplayView()
                    .frame(minWidth: 800, minHeight: 600)
                    .background(Color.black)
                    .navigationTitle("Windows 11 ARM64")
                    .toolbar {
                        ToolbarItemGroup(placement: .status) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(session.shutdownRequestPending ? .orange : .green)
                                    .frame(width: 8, height: 8)

                                Text(session.shutdownRequestPending ? "Shutting Down" : displayManager.activeRenderSource)
                                    .font(.caption.weight(.medium))

                                Text("•")
                                    .foregroundStyle(.tertiary)

                                Text("\(displayManager.activeWidth) × \(displayManager.activeHeight)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)

                                if showFPSTelemetry && displayManager.currentFPS > 0 {
                                    Text("•")
                                        .foregroundStyle(.tertiary)
                                    Text(String(format: "%.0f fps", displayManager.currentFPS))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }

                                if let startDate = session.sessionStartDate {
                                    Text("•")
                                        .foregroundStyle(.tertiary)
                                    Text(startDate, style: .timer)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }

                                if let status = session.lastStatusMessage {
                                    Text("•")
                                        .foregroundStyle(.tertiary)
                                    Text(status)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                        }

                        ToolbarItemGroup(placement: .primaryAction) {
                            Menu {
                                Toggle("Auto-Fit Window", isOn: $displayManager.autoResizeEnabled)
                                Toggle("Fill Screen (Stretch)", isOn: $displayManager.fillScreen)
                                Divider()
                                ForEach(Array(FluxDisplayManager.supportedModes.enumerated()), id: \.offset) { _, mode in
                                    Button {
                                        displayManager.autoResizeEnabled = false
                                        displayManager.requestResolutionChange(width: mode.width, height: mode.height)
                                    } label: {
                                        let isCurrent = displayManager.activeWidth == mode.width && displayManager.activeHeight == mode.height
                                        Text(isCurrent ? "✓ \(mode.width) × \(mode.height)" : "\(mode.width) × \(mode.height)")
                                    }
                                }
                            } label: {
                                Label("Display", systemImage: "display")
                            }
                            .help("Display Resolution & Auto-Fit")

                            Menu {
                                Button {
                                    session.sendCtrlAltDel()
                                } label: {
                                    Label("Send Ctrl+Alt+Del", systemImage: "keyboard")
                                }
                                .disabled(!session.isRunning || session.isSendingSecureAttention)

                                Button {
                                    session.pasteMacClipboardToGuest()
                                } label: {
                                    Label("Paste Mac Clipboard (⇧⌘V)", systemImage: "doc.on.clipboard")
                                }
                                .disabled(!session.isRunning || session.isPastingClipboard)

                                Button {
                                    session.captureScreenshot()
                                } label: {
                                    Label("Take Screenshot (⇧⌘S)", systemImage: "camera")
                                }
                                .disabled(!session.isRunning)

                                Divider()

                                Button {
                                    showingConfigureSheet = true
                                } label: {
                                    Label("Configure...", systemImage: "gearshape")
                                }
                            } label: {
                                Label("Actions", systemImage: "ellipsis.circle")
                            }
                            .help("VM Actions (Ctrl+Alt+Del, Clipboard, Screenshot)")

                            Menu {
                                Button("Shut Down Windows") {
                                    session.requestGuestShutdown()
                                }
                                .disabled(!session.isRunning || session.shutdownRequestPending)

                                Button("Restart Windows") {
                                    session.requestGuestRestart()
                                }
                                .disabled(!session.isRunning || session.shutdownRequestPending)

                                Divider()

                                Button("Force Stop VM...", role: .destructive) {
                                    showingForceStopAlert = true
                                }
                                .disabled(!session.isRunning)
                            } label: {
                                Label(
                                    session.shutdownRequestPending ? "Shutting Down..." : "Power",
                                    systemImage: "power"
                                )
                            }
                            .help("Shut Down, Restart, or Force Stop Windows")

                            Button {
                                session.toggleFullScreen()
                            } label: {
                                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .help("Toggle Full Screen (^⌘F)")
                        }
                    }
            } else {
                controlCenterView
            }
        }
        .sheet(isPresented: $showingConfigureSheet) {
            configureSheet
        }
        .alert("Force Stop Windows 11?", isPresented: $showingForceStopAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Force Stop", role: .destructive) {
                session.forceStop()
            }
        } message: {
            Text("Forcing the virtual machine to stop immediately may cause unsaved work in Windows to be lost.")
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["FLUX_RESET_DISK_VALIDATION"] == "1" {
                DispatchQueue.global(qos: .userInitiated).async {
                    let passed = FluxEngine().runResetDiskValidation()
                    exit(passed ? 0 : 1)
                }
            } else if CommandLine.arguments.contains("--benchmark-nvme") ||
               ProcessInfo.processInfo.environment["FLUX_BENCHMARK_NVME"] == "1" {
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = FluxEngine().runNVMeBenchmark(targetMB: 100)
                    exit(0)
                }
            } else if ProcessInfo.processInfo.environment["FLUX_MSIX_STRESS"] == "1" {
                DispatchQueue.global(qos: .userInitiated).async {
                    // 256 MiB / 128 KiB = exactly 2,048 real NVMe reads,
                    // after a separate disposable-image write pass.
                    _ = FluxEngine().runNVMeBenchmark(targetMB: 256)
                    exit(0)
                }
            } else if CommandLine.arguments.contains("--validate-nvme") ||
               ProcessInfo.processInfo.environment["FLUX_VALIDATE_NVME"] == "1" {
                DispatchQueue.global(qos: .userInitiated).async {
                    let passed = FluxEngine().validateNVMe()
                    exit(passed ? 0 : 1)
                }
            } else if ProcessInfo.processInfo.environment["FLUX_AUTO_START"] == "1" ||
               CommandLine.arguments.contains("--auto-start") {
                startEngine()
            }
        }
    }

    private var controlCenterView: some View {
        VStack(spacing: 0) {
            // Parallels-style Control Center Header
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    Text("Flux Control Center")
                        .font(.headline)
                }

                Spacer()

                Button {
                    showingConfigureSheet = true
                } label: {
                    Label("Configure", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Parallels-style VM Row + Hardware Detail Split
            HStack(spacing: 0) {
                // Left: VM Thumbnail & Quick Controls
                VStack(spacing: 16) {
                    ZStack {
                        // Windows 11 Desktop Thumbnail Preview
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.05, green: 0.22, blue: 0.48),
                                        Color(red: 0.09, green: 0.43, blue: 0.82),
                                        Color(red: 0.16, green: 0.62, blue: 0.94)
                                    ],
                                    startPoint: .bottomLeading,
                                    endPoint: .topTrailing
                                )
                            )
                            .frame(width: 280, height: 175)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.22), radius: 12, y: 6)

                        // Subtle Windows 11 4-pane emblem in background
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.16))

                        // Centered Parallels-style Play Button / Boot Spinner
                        if session.isRunning {
                            VStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(.white)
                                Text("Starting Windows 11...")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white)
                            }
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            Button {
                                startEngine()
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(.ultraThinMaterial)
                                        .frame(width: 68, height: 68)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(.white.opacity(0.45), lineWidth: 1.5)
                                        )
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 26, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .offset(x: 2)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Start Windows 11")
                        }
                    }

                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Windows 11")
                                .font(.title3.weight(.semibold))
                            Text(session.isRunning ? "Starting" : "Stopped")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    (session.isRunning ? Color.orange : Color.secondary).opacity(0.16),
                                    in: Capsule()
                                )
                                .foregroundStyle(session.isRunning ? .orange : .secondary)
                        }
                        Text("ARM64 • Apple Silicon Hypervisor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(24)
                .frame(width: 340)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

                Divider()

                // Right: Hardware & Display Summary (Parallels Inspector Style)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Configuration")
                        .font(.headline)

                    VStack(spacing: 10) {
                        hardwareRow(icon: "cpu", title: "Processors", detail: "4 ARM64 vCPUs (Hypervisor.framework)")
                        hardwareRow(icon: "memorychip", title: "Memory", detail: "4 GB Guest RAM")
                        hardwareRow(icon: "display", title: "Graphics", detail: "Metal + FluxIdd (ProMotion 120Hz)")
                        hardwareRow(icon: "internaldrive", title: "Hard Disk", detail: "64 GB NVMe (flux-target-disk.raw)")
                        hardwareRow(icon: "keyboard", title: "Mouse & Keyboard", detail: "xHCI USB HID Absolute Pointer")
                    }

                    Divider()

                    Toggle("Auto-fit Windows resolution to window size", isOn: $displayManager.autoResizeEnabled)
                        .font(.subheadline)

                    Spacer()

                    HStack {
                        Spacer()
                        if session.isRunning {
                            Button("Force Stop", role: .destructive) {
                                showingForceStopAlert = true
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                startEngine()
                            } label: {
                                Label("Start", systemImage: "play.fill")
                                    .frame(minWidth: 110)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 780, height: 420)
    }

    private func hardwareRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(width: 120, alignment: .leading)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var configureSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Windows 11 ARM64 Configuration", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    showingConfigureSheet = false
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            Form {
                Section("Display & Performance") {
                    Toggle("Auto-Fit Guest Resolution to Window", isOn: $displayManager.autoResizeEnabled)
                    Toggle("Show Live FPS in Toolbar", isOn: $showFPSTelemetry)
                }

                Section("Virtual Hardware") {
                    LabeledContent("Processors", value: "4 ARM64 vCPUs (Hypervisor.framework)")
                    LabeledContent("Graphics", value: "Metal + FluxIdd Indirect Display")
                    LabeledContent("Storage", value: "64 GB NVMe (flux-target-disk.raw)")
                    LabeledContent("Input", value: "xHCI USB HID Keyboard & Absolute Pointer")
                }
            }
            .formStyle(.grouped)
        }
        .padding(20)
        .frame(width: 480, height: 340)
    }

    private func startEngine() {
        session.start()
    }
}

#Preview {
    ContentView()
}
