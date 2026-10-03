import MicropodCore
import SwiftUI

/// Registries tab: managed logins for container registries.
struct RegistriesView: View {
    @Bindable var store: AppStore

    @State private var showLoginSheet = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            WorkspacePageHeader(
                title: "Registries",
                subtitle: "\(store.registries.count) \(store.registries.count == 1 ? "registry" : "registries")",
                icon: "network",
                fallback: "globe"
            ) {
                Button {
                    showLoginSheet = true
                } label: {
                    IconLabel(title: "Log In", icon: "login", fallback: "key")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Tokens.Palette.action)
            }
            .padding(.horizontal, Tokens.Spacing.contentInset)
            .padding(.vertical, Tokens.Spacing.lg)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(errorMessage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }

            Divider()

            if store.registries.isEmpty {
                EmptyStateView(
                    title: String(localized: "No Registry Logins"),
                    description: String(
                        localized:
                            "Log in to pull and push images from private registries. Credentials are stored by the container CLI in the Keychain."
                    ),
                    imageName: EmptyStateArtwork.registries,
                    symbol: "globe",
                    actionTitle: String(localized: "Log In…"),
                    action: { showLoginSheet = true })
            } else {
                List {
                    ForEach(store.registries, id: \.server) { login in
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(login.server).font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(login.server)
                                Text(login.username.isEmpty ? "Logged in" : "Logged in as \(login.username)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(login.username)
                            }
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                            Spacer(minLength: 8)
                            Button {
                                Task {
                                    do {
                                        try await store.logoutRegistry(login.server)
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                IconLabel(
                                    title: "Log Out", icon: "logout", fallback: "rectangle.portrait.and.arrow.right")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Tokens.Palette.canvas)
        .task {
            if store.registries.isEmpty { await store.refreshRegistries() }
        }
        .sheet(isPresented: $showLoginSheet) {
            RegistryLoginSheet(store: store)
        }
    }
}

struct RegistryLoginSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Registry Login").font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Server, e.g. registry.docker.io", text: $server)
                        .textFieldStyle(.roundedBorder)
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password or token", text: $password)
                        .textFieldStyle(.roundedBorder)
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    login()
                } label: {
                    IconLabel(title: "Log In", icon: "login", fallback: "key")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(server.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 420, maxWidth: 640, minHeight: 250, idealHeight: 300, maxHeight: 640)
    }

    private func login() {
        Task {
            do {
                try await store.loginRegistry(server: server, username: username, password: password)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
