import SwiftUI
import PhotosUI
import UIKit

// Native SwiftUI client for the existing Vibegram HTTP API.
// The current backend identifies clients by username; production-grade authentication
// must be added server-side before treating this as a secure public messenger.

private enum VGStyle {
    static let background = Color(hex: 0x0B0D12)
    static let surface = Color(hex: 0x151821)
    static let surface2 = Color(hex: 0x1D2230)
    static let accent = Color(hex: 0x7C6BFF)
    static let accentBlue = Color(hex: 0x4197FF)
    static let muted = Color(hex: 0x9298AA)
    static let border = Color.white.opacity(0.075)
    static let gradient = LinearGradient(colors: [accent, accentBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

private let vgBaseURL = URL(string: "https://vibegramm.onrender.com")!

@MainActor
final class VibegramStore: ObservableObject {
    @Published var currentUsername: String = UserDefaults.standard.string(forKey: "vg_native_username") ?? ""
    @Published var currentProfile: [String: Any] = [:]
    @Published var users: [String: [String: Any]] = [:]
    @Published var messages: [[String: Any]] = []
    @Published var pins: [String: Any] = [:]
    @Published var isRefreshing = false
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private var lastSeenIDs: Set<String> = []
    private var initialSyncComplete = false

    var currentEntity: VGEntity {
        VGEntity(username: currentUsername, fields: currentProfile.isEmpty ? (users[currentUsername] ?? [:]) : currentProfile)
    }

    func signIn(username input: String, name inputName: String, bio inputBio: String = "В Vibegram") async -> Bool {
        let username = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "@", with: "")
        let name = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard username.count >= 3, username.range(of: "^[a-z0-9_]{3,32}$", options: .regularExpression) != nil else {
            errorMessage = "Юзернейм должен содержать 3–32 символа: латинские буквы, цифры или _."
            return false
        }
        guard !name.isEmpty else { errorMessage = "Укажи имя профиля."; return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await post("/api/profile", body: [
                "username": username,
                "name": name,
                "bio": inputBio,
                "color": "#7c6bff",
                "privacy": "everyone"
            ])
            if let err = response["error"] as? String { errorMessage = err; return false }
            currentUsername = username
            UserDefaults.standard.set(username, forKey: "vg_native_username")
            currentProfile = (response["profile"] as? [String: Any]) ?? ["username": username, "name": name, "bio": inputBio]
            errorMessage = nil
            await refresh()
            return true
        } catch {
            errorMessage = "Не удалось подключиться к Vibegram: \(error.localizedDescription)"
            return false
        }
    }

    func signOut() {
        currentUsername = ""
        currentProfile = [:]
        users = [:]
        messages = []
        UserDefaults.standard.removeObject(forKey: "vg_native_username")
        errorMessage = nil
        successMessage = nil
    }

    func refresh(silent: Bool = true) async {
        guard !currentUsername.isEmpty else { return }
        if !silent { isRefreshing = true }
        defer { isRefreshing = false }
        do {
            let url = URL(string: "/api/sync?me=\(currentUsername.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? currentUsername)", relativeTo: vgBaseURL)!
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 18
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw VGError.server("Сервер вернул ошибку.")
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            users = root["users"] as? [String: [String: Any]] ?? [:]
            messages = root["messages"] as? [[String: Any]] ?? []
            pins = root["pins"] as? [String: Any] ?? [:]
            if let serverProfile = users[currentUsername], serverProfile["is_channel"] as? Bool != true {
                currentProfile = serverProfile
            }
            let ids = Set(messages.compactMap { $0["id"] as? String })
            if initialSyncComplete {
                // Foreground UI can react to this set; APNs push is a separate server feature.
                lastSeenIDs = ids
            } else {
                lastSeenIDs = ids
                initialSyncComplete = true
            }
            errorMessage = nil
        } catch {
            if !silent { errorMessage = error.localizedDescription }
        }
    }

    func saveProfile(name: String, bio: String, avatar: String? = nil) async -> Bool {
        guard !currentUsername.isEmpty else { return false }
        var body: [String: Any] = [
            "username": currentUsername,
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "bio": bio,
            "email": currentProfile["email"] as? String ?? "",
            "phone": currentProfile["phone"] as? String ?? "",
            "color": currentProfile["color"] as? String ?? "#7c6bff",
            "privacy": currentProfile["privacy"] as? String ?? "everyone"
        ]
        if let avatar { body["avatar"] = avatar }
        do {
            let response = try await post("/api/profile", body: body)
            if let err = response["error"] as? String { errorMessage = err; return false }
            currentProfile = (response["profile"] as? [String: Any]) ?? currentProfile
            await refresh()
            successMessage = "Профиль сохранён"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func sendMessage(to peer: String, text: String) async -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let peerEntity = entity(peer)
        let sender = peerEntity?.isChannel == true ? (peerEntity?.owner.isEmpty == false ? peerEntity!.owner : currentUsername) : currentUsername
        do {
            let response = try await post("/api/send", body: ["from": sender, "to": peer, "text": clean])
            if let err = response["error"] as? String { errorMessage = err; return false }
            await refresh()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func markRead(peer: String) async {
        _ = try? await post("/api/read", body: ["reader": currentUsername, "peer": peer])
    }

    func subscribe(channel: String) async {
        do {
            let result = try await post("/api/channel/subscribe", body: ["user": currentUsername, "channel": channel])
            if let err = result["error"] as? String { errorMessage = err; return }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func createChannel(username: String, name: String, bio: String) async -> Bool {
        let handle = username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        guard handle.range(of: "^[a-z0-9_]{3,32}$", options: .regularExpression) != nil else {
            errorMessage = "@username канала: латиница, цифры или _ (3–32 символа)."
            return false
        }
        do {
            let response = try await post("/api/channel/save", body: [
                "actor": currentUsername, "owner": currentUsername,
                "username": handle, "name": name, "bio": bio,
                "color": "#4197ff", "avatar": "", "comments_enabled": true,
                "sign_messages": true
            ])
            if let err = response["error"] as? String { errorMessage = err; return false }
            await refresh()
            successMessage = "Канал создан"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func deleteChat(peer: String) async {
        _ = try? await post("/api/delete_chat", body: ["me": currentUsername, "peer": peer])
        await refresh()
    }

    func entity(_ username: String) -> VGEntity? {
        guard let fields = users[username] else { return nil }
        return VGEntity(username: username, fields: fields)
    }

    func lastMessage(for peer: String) -> VGMessage? {
        let relevant = messages.filter { message in
            let sender = message["sender"] as? String ?? ""
            let to = message["to"] as? String ?? ""
            if entity(peer)?.isChannel == true { return to == peer && (message["is_channel_post"] as? Bool ?? false) }
            return (sender == peer && to == currentUsername) || (sender == currentUsername && to == peer)
        }
        return relevant.compactMap { VGMessage($0) }.max { $0.timestamp < $1.timestamp }
    }

    func chatPeers() -> [VGEntity] {
        var handles = Set<String>(["verify_bot"])
        for message in messages {
            let sender = message["sender"] as? String ?? ""
            let to = message["to"] as? String ?? ""
            if sender == currentUsername, to != currentUsername, entity(to)?.isChannel != true { handles.insert(to) }
            if to == currentUsername, sender != currentUsername, entity(sender)?.isChannel != true { handles.insert(sender) }
        }
        let chatPins = pins["chatlist:\(currentUsername)"] as? [String] ?? []
        return handles.compactMap { entity($0) }.sorted { a, b in
            let ap = chatPins.firstIndex(of: a.username) ?? Int.max
            let bp = chatPins.firstIndex(of: b.username) ?? Int.max
            if ap != bp { return ap < bp }
            return (lastMessage(for: a.username)?.timestamp ?? 0) > (lastMessage(for: b.username)?.timestamp ?? 0)
        }
    }

    func contactEntities() -> [VGEntity] {
        users.compactMap { handle, fields in
            guard handle != currentUsername, fields["is_channel"] as? Bool != true else { return nil }
            return VGEntity(username: handle, fields: fields)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func channelEntities() -> [VGEntity] {
        users.compactMap { handle, fields in
            guard fields["is_channel"] as? Bool == true else { return nil }
            return VGEntity(username: handle, fields: fields)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func posts(for channel: String) -> [VGMessage] {
        messages.compactMap { raw in
            guard (raw["to"] as? String) == channel,
                  (raw["is_channel_post"] as? Bool ?? false) else { return nil }
            return VGMessage(raw)
        }.sorted { $0.timestamp > $1.timestamp }
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: path, relativeTo: vgBaseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VGError.server("Нет ответа сервера.") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(http.statusCode) else {
            throw VGError.server(object["error"] as? String ?? "Ошибка HTTP \(http.statusCode)")
        }
        return object
    }
}

private enum VGError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        switch self { case .server(let message): return message }
    }
}

private struct VGEntity: Identifiable {
    let username: String
    let fields: [String: Any]
    var id: String { username }
    var name: String { (fields["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? username }
    var bio: String { fields["bio"] as? String ?? "В Vibegram" }
    var avatar: String { fields["avatar"] as? String ?? "" }
    var colorHex: String { fields["color"] as? String ?? "#7c6bff" }
    var isChannel: Bool { fields["is_channel"] as? Bool ?? false }
    var isBot: Bool { fields["is_bot"] as? Bool ?? false }
    var isVerified: Bool { fields["is_verified"] as? Bool ?? false }
    var isPremium: Bool { fields["is_premium"] as? Bool ?? false }
    var isTeam: Bool { fields["is_team"] as? Bool ?? false }
    var owner: String { fields["owner"] as? String ?? "" }
    var subscribers: [String] { fields["subscribers"] as? [String] ?? [] }
    var isOnline: Bool {
        let lastSeen = fields["last_seen"] as? Double ?? Double(fields["last_seen"] as? Int ?? 0)
        return Date().timeIntervalSince1970 * 1000 - lastSeen < 6500
    }
}

private struct VGMessage: Identifiable {
    let raw: [String: Any]
    init?(_ optional: [String: Any]?) { guard let optional else { return nil }; self.init(optional) }
    init(_ raw: [String: Any]) { self.raw = raw }
    var id: String { raw["id"] as? String ?? UUID().uuidString }
    var sender: String { raw["sender"] as? String ?? "" }
    var to: String { raw["to"] as? String ?? "" }
    var text: String { raw["text"] as? String ?? "" }
    var timestamp: Double { raw["time"] as? Double ?? Double(raw["time"] as? Int ?? 0) }
    var read: Bool { raw["read"] as? Bool ?? false }
    var media: [String: Any] { raw["media"] as? [String: Any] ?? [:] }
    var mediaURL: String { media["url"] as? String ?? media["data"] as? String ?? "" }
    var mediaType: String { media["type"] as? String ?? "" }
    var displayText: String {
        if !text.isEmpty { return text }
        switch mediaType.lowercased() {
        case "image", "photo": return "Фото"
        case "voice": return "Голосовое сообщение"
        case "video", "video_note": return "Видео"
        case "file": return "Файл"
        default: return "Сообщение"
        }
    }
    var date: Date { Date(timeIntervalSince1970: timestamp / 1000) }
    var timeLabel: String { date.formatted(date: .omitted, time: .shortened) }
}

struct ContentView: View {
    @StateObject private var store = VibegramStore()

    var body: some View {
        Group {
            if store.currentUsername.isEmpty {
                NativeWelcomeView()
                    .environmentObject(store)
            } else {
                NativeMainTabs()
                    .environmentObject(store)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: store.currentUsername) {
            guard !store.currentUsername.isEmpty else { return }
            await store.refresh(silent: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if Task.isCancelled { break }
                await store.refresh()
            }
        }
        .alert("Vibegram", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

private struct NativeWelcomeView: View {
    @EnvironmentObject private var store: VibegramStore
    @State private var username = ""
    @State private var name = ""
    @State private var showDetails = false

    var body: some View {
        ZStack {
            VGStyle.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 29, style: .continuous).fill(VGStyle.gradient).frame(width: 100, height: 100)
                        .shadow(color: VGStyle.accent.opacity(0.32), radius: 30, y: 12)
                    Image(systemName: "paperplane.fill").font(.system(size: 44, weight: .semibold)).foregroundStyle(.white).rotationEffect(.degrees(-12))
                }
                Text("Vibegram").font(.system(size: 36, weight: .bold, design: .rounded)).padding(.top, 22)
                Text("Твоё пространство для общения").font(.subheadline).foregroundStyle(VGStyle.muted).padding(.top, 6)
                VStack(spacing: 14) {
                    if showDetails {
                        VGTextField(title: "Имя", placeholder: "Как тебя называть", text: $name, icon: "person")
                    }
                    VGTextField(title: "Юзернейм", placeholder: "username", text: $username, icon: "at")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        if showDetails {
                            Task { if await store.signIn(username: username, name: name) {} }
                        } else {
                            showDetails = true
                        }
                    } label: {
                        HStack { if store.isWorking { ProgressView().tint(.white) }; Text(showDetails ? "Создать профиль" : "Продолжить").fontWeight(.semibold); Spacer(); Image(systemName: "arrow.right") }
                            .padding(.horizontal, 18).frame(height: 54).background(VGStyle.gradient).clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    }
                    .disabled(store.isWorking || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (showDetails && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
                .padding(20).background(VGStyle.surface).clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(VGStyle.border, lineWidth: 1))
                .padding(.top, 36)
                Text("Продолжая, ты создаёшь профиль на сервере Vibegram.")
                    .font(.footnote).foregroundStyle(VGStyle.muted).multilineTextAlignment(.center).padding(.top, 18)
                Spacer()
                Text("Нативный iOS-клиент • Vibegram").font(.caption2).foregroundStyle(VGStyle.muted.opacity(0.7)).padding(.bottom, 14)
            }
            .padding(.horizontal, 22)
        }
    }
}

private struct NativeMainTabs: View {
    @EnvironmentObject private var store: VibegramStore
    var body: some View {
        TabView {
            ChatsHomeView().tabItem { Label("Чаты", systemImage: "bubble.left.and.bubble.right.fill") }
            ContactsHomeView().tabItem { Label("Контакты", systemImage: "person.2.fill") }
            ChannelsHomeView().tabItem { Label("Каналы", systemImage: "dot.radiowaves.left.and.right") }
            ProfileHomeView().tabItem { Label("Профиль", systemImage: "person.crop.circle.fill") }
        }
        .tint(VGStyle.accent)
    }
}

private struct ChatsHomeView: View {
    @EnvironmentObject private var store: VibegramStore
    @State private var search = ""
    @State private var showNewChat = false
    var filtered: [VGEntity] { store.chatPeers().filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.username.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        NavigationStack {
            ZStack {
                VGStyle.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Vibegram").font(.system(size: 31, weight: .bold, design: .rounded))
                                Text("Твои разговоры, в одном месте").font(.subheadline).foregroundStyle(VGStyle.muted)
                            }
                            Spacer()
                            Button { showNewChat = true } label: {
                                Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 46, height: 46).background(VGStyle.surface2).clipShape(Circle())
                            }
                            .accessibilityLabel("Новое сообщение")
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(VGStyle.muted)
                            TextField("Поиск чатов", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(VGStyle.muted) } }
                        }
                        .padding(.horizontal, 14).frame(height: 48).background(VGStyle.surface).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        if filtered.isEmpty {
                            EmptyStateView(icon: "bubble.left.and.bubble.right", title: "Пока тихо", subtitle: "Найди человека во вкладке «Контакты» и начни разговор.")
                                .padding(.top, 50)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(filtered) { peer in
                                    NavigationLink(destination: NativeChatView(peerUsername: peer.username)) {
                                        ChatListRow(entity: peer, message: store.lastMessage(for: peer.username))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 28)
                }
                .refreshable { await store.refresh(silent: false) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showNewChat) { ContactsHomeView(selectMode: true) }
        }
    }
}

private struct ChatListRow: View {
    let entity: VGEntity
    let message: VGMessage?
    var body: some View {
        HStack(spacing: 13) {
            VGAvatar(entity: entity, size: 56, showOnline: !entity.isChannel)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(entity.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    EntityBadges(entity: entity)
                    Spacer(minLength: 4)
                    if let message { Text(message.timeLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(VGStyle.muted) }
                }
                Text(message?.displayText ?? entity.bio).font(.system(size: 13.5)).foregroundStyle(VGStyle.muted).lineLimit(1)
                Text("@\(entity.username)").font(.system(size: 11, weight: .medium)).foregroundStyle(VGStyle.accent.opacity(0.95)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .background(Color.white.opacity(0.001))
    }
}

private struct ContactsHomeView: View {
    @EnvironmentObject private var store: VibegramStore
    var selectMode = false
    @State private var search = ""
    @State private var selected: VGEntity?

    var contacts: [VGEntity] {
        store.contactEntities().filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.username.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if contacts.isEmpty {
                    Text("Пользователи появятся здесь после регистрации на Vibegram.").foregroundStyle(VGStyle.muted).listRowBackground(VGStyle.background)
                }
                ForEach(contacts) { entity in
                    NavigationLink(destination: selectMode ? AnyView(NativeChatView(peerUsername: entity.username)) : AnyView(ContactProfileView(username: entity.username))) {
                        HStack(spacing: 12) {
                            VGAvatar(entity: entity, size: 48, showOnline: true)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) { Text(entity.name).fontWeight(.semibold); EntityBadges(entity: entity) }
                                Text("@\(entity.username)").font(.caption).foregroundStyle(VGStyle.muted)
                            }
                            Spacer()
                            Circle().fill(entity.isOnline ? Color.green : VGStyle.muted.opacity(0.35)).frame(width: 7, height: 7)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(VGStyle.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(VGStyle.background)
            .navigationTitle(selectMode ? "Новое сообщение" : "Контакты")
            .searchable(text: $search, prompt: "Имя или @username")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { Task { await store.refresh(silent: false) } } label: { Image(systemName: "arrow.clockwise") } } }
        }
    }
}

private struct ChannelsHomeView: View {
    @EnvironmentObject private var store: VibegramStore
    @State private var search = ""
    @State private var createPresented = false
    var channels: [VGEntity] { store.channelEntities().filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.username.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Каналы").font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("Новости и публикации сообществ").font(.subheadline).foregroundStyle(VGStyle.muted)
                        }
                        Spacer()
                        Button { createPresented = true } label: { Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44).background(VGStyle.gradient).clipShape(Circle()) }
                    }
                    HStack { Image(systemName: "magnifyingglass").foregroundStyle(VGStyle.muted); TextField("Поиск каналов", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        .padding(14).background(VGStyle.surface).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    if channels.isEmpty { EmptyStateView(icon: "dot.radiowaves.left.and.right", title: "Каналов пока нет", subtitle: "Создай свой канал или зайди позже — здесь появятся сообщества.") }
                    ForEach(channels) { channel in NavigationLink(destination: ChannelDetailView(channelUsername: channel.username)) { ChannelCard(entity: channel, lastMessage: store.lastMessage(for: channel.username)) }.buttonStyle(.plain) }
                }
                .padding(18)
            }
            .background(VGStyle.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $createPresented) { CreateChannelSheet() }
            .refreshable { await store.refresh(silent: false) }
        }
    }
}

private struct ChannelCard: View {
    let entity: VGEntity
    let lastMessage: VGMessage?
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VGAvatar(entity: entity, size: 60)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) { Text(entity.name).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).lineLimit(1); EntityBadges(entity: entity) }
                Text("@\(entity.username)").font(.caption).foregroundStyle(VGStyle.accent)
                Text(lastMessage?.displayText ?? entity.bio).font(.system(size: 13)).foregroundStyle(VGStyle.muted).lineLimit(2)
                Label("\(entity.subscribers.count) подписчиков", systemImage: "person.2.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(VGStyle.muted).padding(.top, 2)
            }
            Spacer(minLength: 2)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(VGStyle.muted).padding(.top, 6)
        }
        .padding(14).background(VGStyle.surface).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(VGStyle.border, lineWidth: 1))
    }
}

private struct ChannelDetailView: View {
    @EnvironmentObject private var store: VibegramStore
    let channelUsername: String
    @State private var postText = ""
    @State private var sending = false

    var channel: VGEntity? { store.entity(channelUsername) }
    var isSubscribed: Bool { channel?.subscribers.contains(store.currentUsername) ?? false }
    var canPost: Bool { channel?.owner == store.currentUsername }

    var body: some View {
        ZStack {
            VGStyle.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let channel {
                        VStack(spacing: 11) {
                            VGAvatar(entity: channel, size: 92)
                            HStack(spacing: 6) { Text(channel.name).font(.system(size: 23, weight: .bold, design: .rounded)); EntityBadges(entity: channel) }
                            Text("@\(channel.username)").font(.subheadline).foregroundStyle(VGStyle.accent)
                            Text(channel.bio).font(.subheadline).foregroundStyle(VGStyle.muted).multilineTextAlignment(.center)
                            HStack(spacing: 22) {
                                StatPill(value: "\(channel.subscribers.count)", title: "Подписчики")
                                StatPill(value: "\(store.posts(for: channelUsername).count)", title: "Публикации")
                            }.padding(.vertical, 4)
                            Button { Task { await store.subscribe(channel: channelUsername) } } label: {
                                Text(isSubscribed ? "Вы подписаны" : "Подписаться")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 48)
                                    .background(isSubscribed ? VGStyle.surface2 : VGStyle.gradient).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            }
                        }
                        .padding(20).frame(maxWidth: .infinity).background(VGStyle.surface).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                        if canPost {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Новая публикация").font(.headline)
                                TextField("Поделись новостью…", text: $postText, axis: .vertical).lineLimit(2...5).padding(12).background(VGStyle.surface2).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                Button { Task { sending = true; let ok = await store.sendMessage(to: channelUsername, text: postText); if ok { postText = "" }; sending = false } } label: { Label("Опубликовать", systemImage: "paperplane.fill").frame(maxWidth: .infinity).padding(13).background(VGStyle.gradient).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                                    .disabled(postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                            }
                            .padding(15).background(VGStyle.surface).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        Text("Публикации").font(.title3.bold()).padding(.top, 4)
                        let posts = store.posts(for: channelUsername)
                        if posts.isEmpty { EmptyStateView(icon: "text.bubble", title: "Публикаций пока нет", subtitle: "Новые посты канала появятся здесь.") }
                        ForEach(posts) { post in VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(channel.name).font(.subheadline.weight(.semibold)); Spacer(); Text(post.timeLabel).font(.caption).foregroundStyle(VGStyle.muted) }
                            Text(post.text.isEmpty ? post.displayText : post.text).font(.body).foregroundStyle(.white).textSelection(.enabled)
                            HStack { Label("\((post.raw["views"] as? [String] ?? []).count)", systemImage: "eye"); Spacer(); Label("\((post.raw["comments"] as? [[String: Any]] ?? []).count)", systemImage: "bubble.right") }.font(.caption).foregroundStyle(VGStyle.muted)
                        }.padding(15).background(VGStyle.surface).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)) }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(channel?.name ?? "Канал")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CreateChannelSheet: View {
    @EnvironmentObject private var store: VibegramStore
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var name = ""
    @State private var bio = ""
    @State private var creating = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Информация") {
                    TextField("Название канала", text: $name)
                    TextField("username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Описание", text: $bio, axis: .vertical).lineLimit(3...6)
                }
                Section { Text("Канал будет создан от имени текущего профиля. Не указывай личные данные, которые не хочешь публиковать.").font(.footnote).foregroundStyle(VGStyle.muted) }
            }
            .scrollContentBackground(.hidden).background(VGStyle.background)
            .navigationTitle("Новый канал")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") { Task { creating = true; let ok = await store.createChannel(username: username, name: name, bio: bio); creating = false; if ok { dismiss() } } }
                        .disabled(creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

private struct ProfileHomeView: View {
    @EnvironmentObject private var store: VibegramStore
    @State private var editPresented = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        VGAvatar(entity: store.currentEntity, size: 96)
                        HStack(spacing: 6) { Text(store.currentEntity.name).font(.system(size: 23, weight: .bold, design: .rounded)); EntityBadges(entity: store.currentEntity) }
                        Text("@\(store.currentUsername)").font(.subheadline).foregroundStyle(VGStyle.accent)
                        Text(store.currentEntity.bio).font(.subheadline).foregroundStyle(VGStyle.muted).multilineTextAlignment(.center)
                        Button { editPresented = true } label: { Label("Редактировать профиль", systemImage: "pencil").font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10).background(VGStyle.surface2).clipShape(Capsule()) }
                    }
                    .frame(maxWidth: .infinity).padding(22).background(VGStyle.surface).clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Твои каналы").font(.title3.bold())
                        let owned = store.channelEntities().filter { $0.owner == store.currentUsername }
                        if owned.isEmpty {
                            HStack(spacing: 12) { Image(systemName: "dot.radiowaves.left.and.right").font(.title2).foregroundStyle(VGStyle.accent).frame(width: 44, height: 44).background(VGStyle.surface2).clipShape(RoundedRectangle(cornerRadius: 13)); VStack(alignment: .leading, spacing: 4) { Text("Создай своё сообщество").font(.subheadline.weight(.semibold)); Text("Канал появится в профиле после создания.").font(.caption).foregroundStyle(VGStyle.muted) } }
                        } else {
                            ForEach(owned) { channel in NavigationLink(destination: ChannelDetailView(channelUsername: channel.username)) { ChannelCard(entity: channel, lastMessage: store.lastMessage(for: channel.username)) }.buttonStyle(.plain) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(17).background(VGStyle.surface).clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))

                    VStack(spacing: 0) {
                        SettingsRow(icon: "bell.badge", title: "Уведомления", subtitle: "Системные push требуют настройки сервера") {
                            Task { await store.refresh(silent: false); store.successMessage = "Обновление данных выполнено" }
                        }
                        Divider().overlay(VGStyle.border).padding(.leading, 54)
                        SettingsRow(icon: "arrow.clockwise", title: "Синхронизировать", subtitle: "Обновить профиль, чаты и каналы") { Task { await store.refresh(silent: false) } }
                        Divider().overlay(VGStyle.border).padding(.leading, 54)
                        SettingsRow(icon: "info.circle", title: "О Vibegram", subtitle: "Нативный клиент для iOS") { store.successMessage = "Vibegram iOS • подключён к vibegramm.onrender.com" }
                        Divider().overlay(VGStyle.border).padding(.leading, 54)
                        SettingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Выйти из профиля", subtitle: "Удалить профиль с этого устройства", destructive: true) { confirmSignOut = true }
                    }.padding(.horizontal, 14).background(VGStyle.surface).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(16)
            }
            .background(VGStyle.background)
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $editPresented) { EditProfileSheet() }
            .confirmationDialog("Выйти из Vibegram?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { store.signOut() }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Серверный профиль не удаляется. На устройстве будет удалено только сохранённое имя входа.") }
            .alert("Vibegram", isPresented: Binding(get: { store.successMessage != nil }, set: { if !$0 { store.successMessage = nil } })) {
                Button("Готово", role: .cancel) { store.successMessage = nil }
            } message: { Text(store.successMessage ?? "") }
        }
    }
}

private struct EditProfileSheet: View {
    @EnvironmentObject private var store: VibegramStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bio = ""
    @State private var avatarData = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            VGAvatar(entity: VGEntity(username: store.currentUsername, fields: ["name": name, "avatar": avatarData.isEmpty ? store.currentEntity.avatar : avatarData, "color": store.currentEntity.colorHex]), size: 88)
                            PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) { Label("Изменить фотографию", systemImage: "photo").font(.subheadline.weight(.medium)) }
                        }
                        Spacer()
                    }.listRowBackground(Color.clear)
                    TextField("Имя", text: $name)
                    TextField("О себе", text: $bio, axis: .vertical).lineLimit(2...5)
                } header: { Text("Профиль") }
                Section { Text("Аватар сохранится на сервере и появится на других устройствах после синхронизации.").font(.footnote).foregroundStyle(VGStyle.muted) }
            }
            .scrollContentBackground(.hidden).background(VGStyle.background)
            .navigationTitle("Редактировать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "Сохранение…" : "Сохранить") { Task { saving = true; let ok = await store.saveProfile(name: name, bio: bio, avatar: avatarData.isEmpty ? nil : avatarData); saving = false; if ok { dismiss() } } }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .task { name = store.currentEntity.name; bio = store.currentEntity.bio }
            .onChange(of: selectedPhoto) { item in
                Task {
                    guard let item, let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.76) else { return }
                    avatarData = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

private struct ContactProfileView: View {
    @EnvironmentObject private var store: VibegramStore
    let username: String
    var body: some View {
        let entity = store.entity(username) ?? VGEntity(username: username, fields: [:])
        VStack(spacing: 16) {
            VGAvatar(entity: entity, size: 100)
            HStack(spacing: 6) { Text(entity.name).font(.title2.bold()); EntityBadges(entity: entity) }
            Text("@\(entity.username)").foregroundStyle(VGStyle.accent)
            Text(entity.bio).multilineTextAlignment(.center).foregroundStyle(VGStyle.muted)
            NavigationLink(destination: NativeChatView(peerUsername: username)) {
                Label("Написать сообщение", systemImage: "bubble.left.fill").font(.headline).frame(maxWidth: .infinity).padding(15).background(VGStyle.gradient).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }.buttonStyle(.plain).padding(.top, 10)
            Spacer()
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(VGStyle.background)
        .navigationTitle("Профиль").navigationBarTitleDisplayMode(.inline)
    }
}

private struct NativeChatView: View {
    @EnvironmentObject private var store: VibegramStore
    let peerUsername: String
    @State private var messageText = ""
    @State private var sending = false
    @FocusState private var inputFocused: Bool
    @State private var showDeleteConfirm = false

    var peer: VGEntity { store.entity(peerUsername) ?? VGEntity(username: peerUsername, fields: [:]) }
    var chatMessages: [VGMessage] {
        store.messages.compactMap { raw in
            let sender = raw["sender"] as? String ?? ""
            let to = raw["to"] as? String ?? ""
            if peer.isChannel {
                guard to == peerUsername && (raw["is_channel_post"] as? Bool ?? false) else { return nil }
            } else {
                guard (sender == store.currentUsername && to == peerUsername) || (sender == peerUsername && to == store.currentUsername) else { return nil }
            }
            return VGMessage(raw)
        }.sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        VStack(spacing: 8) {
                            VGAvatar(entity: peer, size: 72, showOnline: !peer.isChannel)
                            Text(peer.name).font(.title3.bold())
                            HStack(spacing: 5) { Text("@\(peer.username)"); EntityBadges(entity: peer) }.font(.caption).foregroundStyle(VGStyle.muted)
                            if peer.isChannel { Text("\(peer.subscribers.count) подписчиков").font(.caption).foregroundStyle(VGStyle.muted) }
                        }.frame(maxWidth: .infinity).padding(.vertical, 20)
                        if chatMessages.isEmpty {
                            EmptyStateView(icon: "sparkles", title: "Начни разговор", subtitle: "Напиши первое сообщение — оно появится здесь.").padding(.vertical, 30)
                        }
                        ForEach(chatMessages) { msg in
                            MessageBubble(message: msg, isMine: !peer.isChannel && msg.sender == store.currentUsername)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 13).padding(.bottom, 12)
                }
                .background(VGStyle.background)
                .onChange(of: chatMessages.count) { _ in if let id = chatMessages.last?.id { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .bottom) } } }
                .onAppear { Task { await store.markRead(peer: peerUsername); if let id = chatMessages.last?.id { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            if !peer.isChannel || peer.owner == store.currentUsername {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Сообщение…", text: $messageText, axis: .vertical).lineLimit(1...5).focused($inputFocused)
                        .padding(.horizontal, 14).padding(.vertical, 12).background(VGStyle.surface2).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Button {
                        let text = messageText
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        messageText = ""
                        sending = true
                        Task { let ok = await store.sendMessage(to: peerUsername, text: text); sending = false; if !ok { messageText = text }; if ok { await store.markRead(peer: peerUsername) } }
                    } label: {
                        Group { if sending { ProgressView().tint(.white) } else { Image(systemName: "arrow.up") .font(.system(size: 17, weight: .bold)) } }
                            .foregroundStyle(.white).frame(width: 46, height: 46).background(VGStyle.gradient).clipShape(Circle())
                    }.disabled(sending || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Отправить")
                }
                .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 8).background(VGStyle.background)
            } else {
                Button { Task { await store.subscribe(channel: peerUsername) } } label: { Text(peer.subscribers.contains(store.currentUsername) ? "Вы подписаны" : "Подписаться на канал").fontWeight(.semibold).frame(maxWidth: .infinity).padding(15).background(VGStyle.gradient).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous)) }.padding(12)
            }
        }
        .background(VGStyle.background)
        .navigationTitle(peer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) { showDeleteConfirm = true } label: { Label(peer.isChannel ? "Отписаться / удалить канал" : "Очистить чат", systemImage: "trash") }
                    Button { Task { await store.refresh(silent: false) } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            }
        }
        .confirmationDialog("Удалить переписку?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { Task { await store.deleteChat(peer: peerUsername) } }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Удаление синхронизируется с сервером.") }
    }
}

private struct MessageBubble: View {
    let message: VGMessage
    let isMine: Bool
    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 54) }
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty { Text(message.text).font(.system(size: 15.5)).foregroundStyle(.white).textSelection(.enabled) }
                if !message.mediaURL.isEmpty, let url = resolvedMediaURL(message.mediaURL) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit().frame(maxHeight: 230).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
                        else { ProgressView().tint(.white).frame(width: 180, height: 80) }
                    }
                } else if message.text.isEmpty {
                    Label(message.displayText, systemImage: "paperclip").font(.subheadline).foregroundStyle(.white.opacity(0.9))
                }
                HStack(spacing: 4) {
                    Text(message.timeLabel)
                    if isMine { Image(systemName: message.read ? "checkmark.circle.fill" : "checkmark").font(.system(size: 10, weight: .semibold)) }
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.53)).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(isMine ? LinearGradient(colors: [Color(hex: 0x6554DE), Color(hex: 0x426BE8)], startPoint: .topLeading, endPoint: .bottomTrailing) : LinearGradient(colors: [VGStyle.surface2, VGStyle.surface2], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !isMine { Spacer(minLength: 54) }
        }
    }
}

private struct VGAvatar: View {
    let entity: VGEntity
    let size: CGFloat
    var showOnline = false
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarImage
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
            if showOnline && entity.isOnline {
                Circle().fill(Color(hex: 0x35D49A)).frame(width: max(10, size * 0.19), height: max(10, size * 0.19))
                    .overlay(Circle().stroke(VGStyle.background, lineWidth: 2)).offset(x: 1, y: 1)
            }
        }
        .accessibilityLabel("Аватар \(entity.name)")
    }

    @ViewBuilder private var avatarImage: some View {
        let value = entity.avatar
        if value.hasPrefix("data:image"), let comma = value.firstIndex(of: ","), let data = Data(base64Encoded: String(value[value.index(after: comma)...]), options: .ignoreUnknownCharacters), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let url = resolvedMediaURL(value) {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { fallback }
            }
        } else { fallback }
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x353A50), Color(hex: 0x282B3B)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if entity.isBot { Image(systemName: "checkmark.seal.fill").font(.system(size: size * 0.38)).foregroundStyle(VGStyle.accentBlue) }
            else { Text(String(entity.name.prefix(1)).uppercased()).font(.system(size: size * 0.38, weight: .bold, design: .rounded)).foregroundStyle(.white) }
        }
    }
}

private struct EntityBadges: View {
    let entity: VGEntity
    var body: some View {
        HStack(spacing: 3) {
            if entity.isVerified { Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: 0x38A8FF)) }
            if entity.isPremium { Image(systemName: "star.circle.fill").foregroundStyle(Color(hex: 0xF3B941)) }
            if entity.isTeam { Image(systemName: "star.fill").foregroundStyle(VGStyle.accent) }
        }.font(.system(size: 11, weight: .semibold))
    }
}

private struct VGTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(VGStyle.muted)
            HStack(spacing: 10) { Image(systemName: icon).foregroundStyle(VGStyle.accent).frame(width: 18); TextField(placeholder, text: $text).foregroundStyle(.white) }
                .padding(.horizontal, 13).frame(height: 48).background(VGStyle.surface2).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }
}

private struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30, weight: .medium)).foregroundStyle(VGStyle.accent)
                .frame(width: 74, height: 74).background(VGStyle.surface2).clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(VGStyle.muted).multilineTextAlignment(.center).frame(maxWidth: 290)
        }.frame(maxWidth: .infinity).padding(.vertical, 28)
    }
}

private struct StatPill: View {
    let value: String
    let title: String
    var body: some View { VStack(spacing: 3) { Text(value).font(.system(size: 18, weight: .bold, design: .rounded)); Text(title).font(.caption).foregroundStyle(VGStyle.muted) }.frame(minWidth: 90) }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(destructive ? Color.red : VGStyle.accent).frame(width: 40, height: 40).background(VGStyle.surface2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(destructive ? Color.red : .white); Text(subtitle).font(.system(size: 11.5)).foregroundStyle(VGStyle.muted).multilineTextAlignment(.leading) }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(VGStyle.muted)
            }.padding(.vertical, 11).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private func resolvedMediaURL(_ raw: String) -> URL? {
    guard !raw.isEmpty, !raw.hasPrefix("data:") else { return nil }
    if let url = URL(string: raw), url.scheme != nil { return url }
    return URL(string: raw, relativeTo: vgBaseURL)?.absoluteURL
}
