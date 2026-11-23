import SwiftUI

/// One account the list offers, with the vault it is in.
struct AccountRow: Identifiable {
  let vault: String
  let account: AutofillAccount
  var id: String { "\(vault)/\(account.id)" }
}

/// What the list shows: the accounts for the website first, then every account.
struct AccountListModel {
  let rows: [AccountRow]
  /// The website asking for a code, if iOS said.
  let host: String?
  /// The rows for [host]: by their domains, or because the person picked them there before.
  let suggested: [AccountRow]

  init(copies: [AutofillCopy], host: String?, picked: Set<String>) {
    rows = copies.flatMap { copy in copy.accounts.map { AccountRow(vault: copy.vault, account: $0) } }
      .sorted { $0.account.name.localizedCaseInsensitiveCompare($1.account.name) == .orderedAscending }
    self.host = host
    if let host {
      suggested = rows.filter { picked.contains($0.id) || HostMatch.matches(host: host, domains: $0.account.domains) }
    } else {
      suggested = []
    }
  }
}

/// The accounts to fill from, searchable, with the website's own first. When
/// none is the website's, the person can remember their pick for it, and is
/// told Kemlock doesn't know the site for that account.
struct AccountListView: View {
  let model: AccountListModel
  let onPick: (AccountRow, Bool) -> Void
  let onCancel: () -> Void

  @State private var query = ""
  @State private var remember = false

  private func found(_ rows: [AccountRow]) -> [AccountRow] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return rows }
    return rows.filter { $0.account.issuer.localizedCaseInsensitiveContains(q) || $0.account.label.localizedCaseInsensitiveContains(q) }
  }

  var body: some View {
    NavigationStack {
      List {
        if model.rows.isEmpty {
          Text("list.empty").foregroundStyle(.secondary)
        }
        let suggested = found(model.suggested)
        if !suggested.isEmpty {
          Section("list.suggested") {
            ForEach(suggested) { row in AccountButton(row: row) { onPick(row, false) } }
          }
        }
        if let host = model.host, model.suggested.isEmpty, !model.rows.isEmpty {
          Section {
            Toggle(isOn: $remember) { Text(String(format: NSLocalizedString("list.remember", comment: ""), host)) }
          } footer: {
            Text(String(format: NSLocalizedString("list.unknownHost", comment: ""), host))
          }
        }
        let all = found(model.rows)
        if !all.isEmpty {
          Section("list.all") {
            ForEach(all) { row in AccountButton(row: row) { onPick(row, remember) } }
          }
        }
      }
      .searchable(text: $query, prompt: Text("list.search"))
      .navigationTitle("Kemlock")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("cancel", action: onCancel) }
      }
    }
  }
}

/// An account in the list: the issuer in bold, the label under it.
private struct AccountButton: View {
  let row: AccountRow
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 2) {
        Text(row.account.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
        if !row.account.issuer.isEmpty, !row.account.label.isEmpty {
          Text(row.account.label).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .accessibilityElement(children: .combine)
  }
}

/// The logins to fill from, searchable, with the website's own first. When
/// none is the website's, the person can remember their pick for it, and is
/// told Kemlock doesn't know the site for these logins.
struct LoginListView: View {
  let model: LoginListModel
  let onPick: (VaultLogin, Bool) -> Void
  let onCancel: () -> Void

  @State private var query = ""
  @State private var remember = false

  var body: some View {
    NavigationStack {
      List {
        if model.rows.isEmpty {
          Text("logins.empty").foregroundStyle(.secondary)
        }
        let suggested = LoginListModel.found(model.suggested, query: query)
        if !suggested.isEmpty {
          Section("list.suggested") {
            ForEach(suggested) { row in LoginButton(login: row.login) { onPick(row, false) } }
          }
        }
        if let host = model.host, model.suggested.isEmpty, !model.rows.isEmpty {
          Section {
            Toggle(isOn: $remember) { Text(String(format: NSLocalizedString("list.remember", comment: ""), host)) }
          } footer: {
            Text(String(format: NSLocalizedString("logins.unknownHost", comment: ""), host))
          }
        }
        let all = LoginListModel.found(model.rows, query: query)
        if !all.isEmpty {
          Section("logins.all") {
            ForEach(all) { row in LoginButton(login: row.login) { onPick(row, remember) } }
          }
        }
      }
      .searchable(text: $query, prompt: Text("list.search"))
      .navigationTitle("Kemlock")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("cancel", action: onCancel) }
      }
    }
  }
}

/// A login in the list: its name in bold, the username under it.
private struct LoginButton: View {
  let login: AutofillLogin
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 2) {
        Text(login.name.isEmpty ? login.shownName : login.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
        if let username = login.username, !login.name.isEmpty {
          Text(username).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .accessibilityElement(children: .combine)
  }
}

/// While Face ID or Touch ID is up.
struct WaitingView: View {
  var body: some View {
    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// A plain message, such as asking to open Kemlock, with a button to close.
struct MessageView: View {
  let message: Text
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(.tint)
        message.multilineTextAlignment(.center)
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Kemlock")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("close", action: onClose) }
      }
    }
  }
}
