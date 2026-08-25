import MicropodCore
import SwiftUI

/// First-run onboarding: a guided 4-step flow (runtime → kernel → pull →
/// run first container) with live status checks reusing store state.
/// Skippable; completion writes `onboardingComplete`.
struct OnboardingTourView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var showRunSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                EmptyStateView.brandMark(EmptyStateArtwork.dashboardHero, size: 30)
                Text(String(localized: "Get Started with Micropod")).font(.title3.weight(.semibold))
                Spacer()
                Button(String(localized: "Skip")) { finish() }
                    .controlSize(.small)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                    stepCard(
                        index: 0,
                        title: String(localized: "1. Start the runtime"),
                        description: String(
                            localized:
                                "Micropod manages Apple's `container` runtime — the VM that runs your containers."),
                        artwork: EmptyStateArtwork.onboardingRuntime,
                        symbol: "power",
                        done: store.isRuntimeRunning,
                        control: {
                            if store.isRuntimeRunning {
                                statusCheck(String(localized: "Runtime running"))
                            } else {
                                Button {
                                    Task { await store.startRuntime() }
                                } label: {
                                    IconLabel(
                                        title: String(localized: "Start Runtime"), icon: "start", fallback: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.isStartingRuntime)
                            }
                        })
                    stepCard(
                        index: 1,
                        title: String(localized: "2. Install the kernel"),
                        description: String(
                            localized:
                                "Containers boot from a kernel image. Micropod installs the recommended one for you."),
                        artwork: EmptyStateArtwork.onboardingKernel,
                        symbol: "cpu",
                        done: store.isKernelInstalled || store.kernelInstallComplete,
                        control: {
                            if store.isKernelInstalled || store.kernelInstallComplete {
                                statusCheck(String(localized: "Kernel installed"))
                            } else if store.isInstallingKernel {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(String(localized: "Installing…")).font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Button {
                                    Task { await store.installRecommendedKernel() }
                                } label: {
                                    IconLabel(
                                        title: String(localized: "Install Recommended Kernel"), icon: "pull",
                                        fallback: "arrow.down.circle")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        })
                    stepCard(
                        index: 2,
                        title: String(localized: "3. Pull a hello image"),
                        description: String(localized: "Pull a small image so you have something to run."),
                        artwork: EmptyStateArtwork.onboardingPull,
                        symbol: "arrow.down.circle",
                        done: !store.images.isEmpty,
                        control: {
                            if !store.images.isEmpty {
                                statusCheck("\(store.images.count) image(s) local")
                            } else {
                                Button {
                                    store.startPull(reference: "alpine:latest", platform: nil)
                                } label: {
                                    IconLabel(
                                        title: String(localized: "Pull alpine:latest"),
                                        icon: "pull", fallback: "arrow.down.circle")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        })
                    stepCard(
                        index: 3,
                        title: String(localized: "4. Run your first container"),
                        description: String(localized: "Create and start a container from the image you pulled."),
                        artwork: EmptyStateArtwork.onboardingRun,
                        symbol: "play.circle",
                        done: store.runningCount > 0,
                        control: {
                            if store.runningCount > 0 {
                                statusCheck("\(store.runningCount) container(s) running")
                            } else {
                                Button {
                                    showRunSheet = true
                                } label: {
                                    IconLabel(
                                        title: String(localized: "Run a Container…"), icon: "start",
                                        fallback: "play.circle")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.images.isEmpty)
                            }
                        })
                }
                .padding(16)
            }

            Divider()

            HStack {
                Text(String(localized: "All set when the checkmarks are green — or skip any time."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Finish")) { finish() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .sheet(isPresented: $showRunSheet) {
            RunContainerSheet(store: store, initialImage: store.images.first?.names.first ?? "alpine:latest")
        }

    }

    private func stepCard<Control: View>(
        index: Int,
        title: String,
        description: String,
        artwork: String?,
        symbol: String,
        done: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            EmptyStateView.brandMark(artwork ?? "", size: 44, symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.semibold))
                    if done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.green)
                    }
                }
                Text(description).font(.caption).foregroundStyle(.secondary)
                control()
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            done ? Color.green.opacity(0.06) : Color.accentColor.opacity(0.05),
            in: RoundedRectangle(cornerRadius: Tokens.Radius.lg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                .stroke(done ? Color.green.opacity(0.25) : Color.accentColor.opacity(0.15), lineWidth: 1))

    }

    private func statusCheck(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(.green)
    }

    private func finish() {
        store.onboardingComplete = true
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.onboardingComplete)
        dismiss()
    }
}
