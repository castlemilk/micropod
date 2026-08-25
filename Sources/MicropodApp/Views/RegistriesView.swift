import MicropodCore
import SwiftUI

/// Registries tab: managed logins for container registries.
struct RegistriesView: View {
    @Bindable var store: AppStore

    @State private var showLoginSheet = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.registries.count) registries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Button {
                    showLoginSheet = true
                } label: {
                    IconLabel(title: "Log In", icon: "login", fallback: "key")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(8)

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
                                Text("Logged in").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !login.username.isEmpty {
                                Text(login.username).font(.caption).foregroundStyle(.secondary)
                            }
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
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
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
            TextField("Server, e.g. registry.docker.io", text: $server)
                .textFieldStyle(.roundedBorder)
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password or token", text: $password)
                .textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
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
        .frame(width: 420)
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
