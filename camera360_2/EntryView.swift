//
//  EntryView.swift
//  camera360_2
//
//  Created by Marc Holland on 05.02.26.
//

import SwiftUI

struct EntryView: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectionCard

            if case .connected = camera.connectionState {
                statusCard
                NavigationLink {
                    CaptureView(camera: camera)
                } label: {
                    Label("Go to Capture", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("To connect, power on your Insta360 camera and join its Wi‑Fi network on this iPhone.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Camera360")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await camera.refreshStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!camera.isConnected)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    camera.reconnect()
                } label: {
                    Image(systemName: "wifi")
                }
            }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(camera.isConnected ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(camera.connectionState.title)
                    .font(.headline)
            }

            if let detail = camera.connectionState.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let battery = camera.batteryPercentage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Battery: \(battery)%")
                        .font(.subheadline.weight(.semibold))
                    ProgressView(value: Double(battery), total: 100)
                }
            } else {
                Text("Battery: —")
                    .foregroundStyle(.secondary)
            }

            if let free = camera.storageFreeBytes, let total = camera.storageTotalBytes, total > 0 {
                let used = Double(total - free) / Double(total)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Storage: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
                        .font(.subheadline.weight(.semibold))
                    ProgressView(value: used, total: 1.0)
                }
            } else {
                Text("Storage: —")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension CameraController.ConnectionState {
    var title: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Connected"
        case .error:
            return "Connection Error"
        }
    }

    var detail: String? {
        switch self {
        case .disconnected:
            return nil
        case .connecting:
            return "Waiting for a camera on Wi‑Fi."
        case let .connected(cameraName):
            return cameraName
        case let .error(message):
            return message
        }
    }
}

#if DEBUG
struct EntryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            EntryView(camera: CameraController())
        }
    }
}
#endif
