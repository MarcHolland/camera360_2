//
//  CaptureView.swift
//  camera360_2
//
//  Created by Marc Holland on 05.02.26.
//

import SwiftUI

struct CaptureView: View {
    @ObservedObject var camera: CameraController

    @Environment(\.dismiss) private var dismiss

    @State private var showDownloadPrompt = false
    @State private var pendingURI: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            if !camera.isConnected {
                Text("Camera not connected.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Back") { dismiss() }
                    .buttonStyle(.bordered)
            } else {
                recordingStatus
                controls
                transferStatus
                exportResult
                Spacer()
            }
        }
        .padding()
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Download & Export?", isPresented: $showDownloadPrompt, actions: {
            Button("Cancel", role: .cancel) {}
            Button("Download & Export") {
                guard let uri = pendingURI else { return }
                Task { await downloadAndExport(uri: uri) }
            }
        }, message: {
            Text("Download the last recording from the camera and export it to an MP4 on your phone.")
        })
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil }), actions: {}, message: {
            Text(errorMessage ?? "")
        })
    }

    private var recordingStatus: some View {
        VStack(spacing: 8) {
            if camera.isRecordingTimelapse, let startDate = camera.recordingStartDate {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let elapsed = Date().timeIntervalSince(startDate)
                    Text(timeString(elapsed))
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                Text("Recording timelapse…")
                    .foregroundStyle(.secondary)
            } else {
                Text("Ready")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var controls: some View {
        HStack(spacing: 24) {
            if camera.isRecordingTimelapse {
                Button {
                    Task { await stopRecording() }
                } label: {
                    CaptureControlButton(kind: .stop)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    Task { await startRecording() }
                } label: {
                    CaptureControlButton(kind: .record)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    private var transferStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = camera.downloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading… \(Int(progress * 100))%")
                        .font(.subheadline.weight(.semibold))
                    ProgressView(value: progress, total: 1.0)
                }
            }

            if let progress = camera.exportProgress {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exporting… \(Int(progress * 100))%")
                        .font(.subheadline.weight(.semibold))
                    ProgressView(value: progress, total: 1.0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exportResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = camera.exportedVideoURL {
                Text("Export complete")
                    .font(.subheadline.weight(.semibold))
                ShareLink(item: url) {
                    Label("Share MP4", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startRecording() async {
        do {
            try await camera.startTimelapseCaptureHighestQuality()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        do {
            let uri = try await camera.stopTimelapseCapture()
            pendingURI = uri
            showDownloadPrompt = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func downloadAndExport(uri: String) async {
        do {
            _ = try await camera.downloadAndExportLastRecording(uri: uri)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func timeString(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private enum CaptureButtonKind {
    case record
    case stop
}

private struct CaptureControlButton: View {
    let kind: CaptureButtonKind

    var body: some View {
        ZStack {
            Circle()
                .fill(kind == .record ? Color.red : Color.gray)
                .frame(width: 86, height: 86)
                .shadow(radius: 6, y: 2)

            if kind == .record {
                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 70, height: 70)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white)
                    .frame(width: 34, height: 34)
            }
        }
        .accessibilityLabel(kind == .record ? "Start timelapse recording" : "Stop recording")
    }
}

#if DEBUG
struct CaptureView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            CaptureView(camera: CameraController())
        }
    }
}
#endif
