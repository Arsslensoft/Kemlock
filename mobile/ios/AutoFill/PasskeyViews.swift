import SwiftUI

/// Where a new passkey goes when several vaults take passkeys: the vault
/// used last first, each by the name the lock screen shows.
struct VaultChoiceView: View {
  let vaults: [PasskeyVault]
  /// The site asking, and the account the passkey is for.
  let site: String
  let user: String
  let onPick: (PasskeyVault) -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(Array(vaults.enumerated()), id: \.element.vault) { position, vault in
            Button {
              onPick(vault)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(vaultName(vault)).font(.body.weight(.semibold)).foregroundStyle(.primary)
                if position == 0 { Text("vaults.last").font(.subheadline).foregroundStyle(.secondary) }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .accessibilityElement(children: .combine)
          }
        } header: {
          Text("vaults.title")
        } footer: {
          Text(user.isEmpty ? site : "\(user) · \(site)")
        }
      }
      .navigationTitle("Kemlock")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("cancel", action: onCancel) }
      }
    }
  }
}

/// The passkeys a site may sign in with when Kemlock holds several: by user
/// name, with the display name, and the vault when they come from several.
struct PasskeyListView: View {
  let passkeys: [VaultPasskey]
  let site: String
  /// The name of each vault, by id.
  let vaultNames: [String: String]
  let onPick: (VaultPasskey) -> Void
  let onCancel: () -> Void

  var body: some View {
    let severalVaults = Set(passkeys.map(\.vault)).count > 1
    NavigationStack {
      List {
        Section(String(format: NSLocalizedString("passkeys.title", comment: ""), site)) {
          ForEach(passkeys, id: \.record) { entry in
            Button {
              onPick(entry)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.passkey.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                let details = [
                  entry.passkey.userDisplayName.flatMap { $0 == entry.passkey.name ? nil : $0 },
                  severalVaults ? vaultNames[entry.vault] ?? NSLocalizedString("vaults.defaultName", comment: "") : nil,
                ].compactMap { $0 }
                if !details.isEmpty { Text(details.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary) }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .accessibilityElement(children: .combine)
          }
        }
      }
      .navigationTitle("Kemlock")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("cancel", action: onCancel) }
      }
    }
  }
}

/// Where a new login goes when several vaults save logins (IosSave.dc.html):
/// the site or app, the username and the password hidden, then the vaults,
/// the one used last picked first, and Save to the one picked.
struct LoginSaveView: View {
  /// The website the login is for, or nil in an app, which [name] names.
  let site: String?
  let name: String
  let username: String?
  let vaults: [PasskeyVault]
  let onPick: (PasskeyVault) -> Void
  let onCancel: () -> Void

  @State private var chosen: String?

  var body: some View {
    let picked = vaults.first { $0.vault == chosen } ?? vaults.first
    NavigationStack {
      List {
        Section {
          if let site {
            LabeledContent("save.website", value: site)
          } else {
            LabeledContent("save.app", value: name)
          }
          if let username { LabeledContent("save.username", value: username) }
          LabeledContent("save.password", value: "••••••••••")
        }
        Section {
          ForEach(vaults, id: \.vault) { vault in
            Button {
              chosen = vault.vault
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(vaultName(vault)).font(.body.weight(.semibold)).foregroundStyle(.primary)
                  Text(openedLine(vault)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if vault.vault == picked?.vault { Image(systemName: "checkmark").foregroundStyle(.tint) }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(vault.vault == picked?.vault ? .isSelected : [])
          }
        } header: {
          Text("save.vault")
        } footer: {
          Text("save.note")
        }
      }
      .safeAreaInset(edge: .bottom) {
        Button {
          if let picked { onPick(picked) }
        } label: {
          Text(String(format: NSLocalizedString("save.to", comment: ""), picked.map(vaultName) ?? "")).font(.body.weight(.semibold)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(picked == nil)
        .padding()
      }
      .navigationTitle("save.title")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("save.notNow", action: onCancel) }
      }
    }
  }

  /// When the app last wrote [vault]'s copy, which it does each time the vault is opened: "Opened today".
  private func openedLine(_ vault: PasskeyVault) -> String {
    let calendar = Calendar.current
    let opened = Date(timeIntervalSince1970: Double(vault.writtenAt) / 1000)
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: opened), to: calendar.startOfDay(for: Date())).day ?? 0
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    formatter.dateTimeStyle = .named
    return String(format: NSLocalizedString("save.opened", comment: ""), formatter.localizedString(from: DateComponents(day: -max(days, 0))))
  }
}

/// The name a vault is listed by: its own, or the first vault's default.
func vaultName(_ vault: PasskeyVault) -> String {
  vault.name ?? NSLocalizedString("vaults.defaultName", comment: "")
}
