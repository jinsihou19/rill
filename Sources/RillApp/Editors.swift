import SwiftUI
import RillCore

struct ConnectionEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var profile: ConnectionProfile
    @State var password: String
    @State private var connectAfter = true
    @State private var testing = false
    @State private var result: String?
    @State private var testSucceeded = false
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(symbol: "externaldrive.badge.plus", title: "连接 Redis", subtitle: "为你的工作空间添加一条可靠的连接。")
            Form {
                Section("连接信息") {
                    TextField("名称", text: $profile.name)
                    Picker("环境", selection: $profile.environment) { ForEach(ConnectionEnvironment.allCases, id: \.self) { Text($0.title).tag($0) } }
                        .onChange(of: profile.environment) { _, value in if value == .production { profile.readOnly = true } }
                    TextField("主机", text: $profile.host).autocorrectionDisabled()
                    TextField("端口", value: $profile.port, format: .number.grouping(.never))
                    TextField("默认 DB", value: $profile.database, format: .number.grouping(.never))
                }
                Section("认证与安全") {
                    TextField("ACL 用户名（可选）", text: $profile.username).autocorrectionDisabled()
                    SecureField("密码（可选）", text: $password)
                    Toggle("TLS 加密连接", isOn: $profile.tls)
                    Toggle("只读模式", isOn: $profile.readOnly)
                    Text(profile.environment == .production ? "生产环境默认只读。关闭后，每次写入都需要输入连接名称确认。" : "密码保存在 macOS 钥匙串。TLS 使用系统信任链验证证书和主机名。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Section {
                    Text("支持 Redis 6.2+ standalone。已有 SSH 隧道可填写本地转发端口；Cluster / Sentinel 暂不支持。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Toggle("保存后连接", isOn: $connectAfter)
                }
                if let result {
                    Label(result, systemImage: testSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(testSucceeded ? .green : .orange).textSelection(.enabled)
                }
                if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).scrollContentBackground(.hidden).disabled(testing)
            Divider()
            HStack {
                Button { testConnection() } label: { if testing { ProgressView().controlSize(.small) } else { Text("测试连接") } }.disabled(testing)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存连接") { model.saveProfile(profile, password: password, connectAfter: connectAfter) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(testing)
            }.padding(20)
        }.frame(width: 520, height: 690).tint(RillTheme.accent)
            .onAppear { model.error = nil }.onDisappear { testTask?.cancel() }
    }
    private func testConnection() {
        result = nil; testing = true
        let configuration = profile, secret = password
        testTask = Task {
            do {
                let db = try await RedisDatabase.connect(configuration, password: secret)
                defer { db.close() }
                guard !Task.isCancelled else { return }
                result = String(format: "连接成功 · Redis %@ · %.1f ms", db.server["redis_version"] ?? "—", db.latency); testSucceeded = true
            } catch { if !Task.isCancelled { result = error.localizedDescription; testSucceeded = false } }
            testing = false
        }
    }
}

struct DataEditor: View {
    enum Mode { case newKey, row(ValueRow?) }
    let mode: Mode
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: KeyKind = .string
    @State private var field = ""
    @State private var value = ""
    @State private var score = "0"
    @State private var ttlText = ""
    @State private var json = false
    @State private var validationError: String?

    private var isNewKey: Bool { if case .newKey = mode { return true }; return false }
    private var existing: ValueRow? { if case .row(let row) = mode { return row }; return nil }
    private var binaryValue: Bool {
        guard let row = existing, kind != .zset else { return false }
        return row.value.contains(0) || String(data: row.value, encoding: .utf8) == nil
    }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(symbol: isNewKey ? "plus.square.on.square" : "pencil.line", title: isNewKey ? "新建键" : existing == nil ? "新增成员" : "编辑成员", subtitle: isNewKey ? "从一个简单的值开始。已有同名键不会被覆盖。" : "只修改当前成员，不覆盖整个集合。")
            Form {
                Section {
                    if isNewKey {
                        TextField("键名", text: $name).fontDesign(.monospaced)
                        Picker("类型", selection: $kind) { ForEach(KeyKind.editable, id: \.self) { Text($0.title).tag($0) } }
                            .onChange(of: kind) { _, new in if new == .stream && value.isEmpty { value = "{\n  \"event\": \"created\"\n}" } }
                    } else if let page = model.detail { LabeledContent("键", value: page.key.name).fontDesign(.monospaced) }
                    if kind == .hash { TextField("Field", text: $field).disabled(existing != nil).fontDesign(.monospaced) }
                    if kind == .list, let row = existing { LabeledContent("Index", value: row.fieldText).fontDesign(.monospaced) }
                    if kind == .zset { TextField("Score", text: $score).fontDesign(.monospaced) }
                    if kind == .string { Toggle("作为 JSON 校验", isOn: $json) }
                    if isNewKey { TextField("TTL 秒（留空永久）", text: $ttlText).fontDesign(.monospaced) }
                }
                Section(kind == .stream ? "字段 JSON（所有值必须为字符串）" : kind == .set || kind == .zset ? "Member" : "Value") {
                    if binaryValue { Label("此值包含二进制字节，当前编辑器不转换或覆盖它。", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary) }
                    CodeTextView(text: $value, editable: !binaryValue && !(kind == .zset && existing != nil)).frame(height: 180)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(RillTheme.border))
                    if kind == .stream { Text("例如 {\"event\":\"created\",\"user_id\":\"42\"}").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                    if kind == .list && existing == nil { Text("新成员追加到列表尾部（RPUSH）。").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                if let validationError { Text(validationError).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Text("\(Data(value.utf8).count.formatted()) 字节").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNewKey ? "创建键" : "保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(binaryValue)
            }.padding(20)
        }.frame(width: 580, height: 650).tint(RillTheme.accent).onAppear {
            if !isNewKey { kind = model.detail?.key.kind ?? .string }
            if let row = existing { field = row.fieldText; value = row.valueText; score = row.score ?? "0" }
            else if kind == .stream { value = "{\n  \"event\": \"created\"\n}" }
        }
    }
    private func save() {
        do {
            let payload = Data(value.utf8)
            guard payload.count <= RedisDatabase.previewLimit else { throw RedisError.message("值不能超过 1 MiB。") }
            if json { _ = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) }
            if kind == .stream { _ = try RedisDatabase.streamFields(payload) }
            if kind == .zset { guard let n = Double(score), n.isFinite else { throw RedisError.message("Score 必须为有限数值。") } }
            let ttl: Int64?
            if ttlText.isEmpty { ttl = nil }
            else { guard let number = Int64(ttlText), number > 0, number <= Int64.max / 1000 else { throw RedisError.message("TTL 请输入正整数秒。"); }; ttl = number }
            if isNewKey {
                guard !name.isEmpty else { throw RedisError.message("请填写键名。") }
                let key = Data(name.utf8), selectedKind = kind, field = Data(field.utf8), score = score
                model.finishEditor { model.mutate("创建键", focusKey: key) { try await $0.create(key: key, kind: selectedKind, field: field, value: payload, score: score, ttl: ttl) } }
            } else if let page = model.detail {
                let field = Data(field.utf8), score = score
                if let row = existing {
                    model.finishEditor { model.mutate("保存成员") { try await $0.saveRow(key: page.key.bytes, kind: page.key.kind, row: row, replacement: payload, score: score, total: page.count) } }
                } else {
                    model.finishEditor { model.mutate("新增成员") { try await $0.addRow(key: page.key.bytes, kind: page.key.kind, field: field, value: payload, score: score) } }
                }
            }
        } catch { validationError = error.localizedDescription }
    }
}

struct MetadataEditor: View {
    enum Mode { case ttl, rename }
    let mode: Mode
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var permanent = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            SheetHeading(symbol: mode == .ttl ? "clock" : "pencil", title: mode == .ttl ? "设置过期时间" : "重命名键", subtitle: model.detail?.key.name ?? "").padding(-24)
            if mode == .ttl {
                if model.detail?.key.ttl == nil { Text("当前 TTL 无法读取。应用后将使用你选择的新过期策略。").font(.caption).foregroundStyle(.orange) }
                Toggle("永久有效", isOn: $permanent)
                HStack { TextField("TTL", text: $value).textFieldStyle(.roundedBorder).disabled(permanent); Text("秒").foregroundStyle(.secondary) }
                Text("从操作成功时开始计时，不更改键值。").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                TextField("新键名", text: $value).textFieldStyle(.roundedBorder).fontDesign(.monospaced)
                Text("使用 RENAMENX，若目标已存在会拒绝覆盖。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("应用") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 440).tint(RillTheme.accent).onAppear {
            if mode == .ttl { let ttl = model.detail?.key.ttl; permanent = ttl == -1; value = String(max(1, (ttl ?? 60_000) / 1000)) }
            else { value = model.detail.flatMap { String(data: $0.key.bytes, encoding: .utf8) } ?? "" }
        }
    }
    private func save() {
        guard let key = model.detail?.key.bytes else { return }
        if mode == .ttl {
            let seconds: Int64?
            if permanent { seconds = nil }
            else { guard let n = Int64(value), n > 0, n <= Int64.max / 1000 else { error = "请输入正整数秒。"; return }; seconds = n }
            model.finishEditor { model.mutate("更新 TTL") { try await $0.expire(key, seconds: seconds) } }
        } else {
            let target = Data(value.utf8)
            guard !target.isEmpty, target != key else { error = "请输入不同的非空键名。"; return }
            model.finishEditor { model.mutate("重命名键", focusKey: target) { try await $0.rename(key, to: target) } }
        }
    }
}

struct ConfirmationView: View {
    let request: ConfirmationRequest
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: request.requiredText.isEmpty ? "exclamationmark.circle" : "shield.lefthalf.filled.trianglebadge.exclamationmark")
                    .font(.system(size: 26, weight: .light)).foregroundStyle(.orange)
                Text(request.title).font(.system(size: 18, weight: .semibold))
            }
            Text(request.message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(8)
            if !request.requiredText.isEmpty {
                Text("输入连接名称「\(request.requiredText)」以确认生产写入。").font(.system(size: 12))
                TextField("连接名称", text: $input).textFieldStyle(.roundedBorder).accessibilityIdentifier("productionConfirmation")
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.button, role: request.destructive ? .destructive : nil) { model.finishConfirmation(request.action) }
                    .buttonStyle(.borderedProminent).tint(request.destructive ? .red : RillTheme.accent)
                    .disabled(!request.requiredText.isEmpty && input != request.requiredText)
            }
        }.padding(26).frame(width: 470)
    }
}

private struct SheetHeading: View {
    let symbol: String, title: String, subtitle: String
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 23, weight: .light)).foregroundStyle(RillTheme.accent).frame(width: 35)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }.padding(24)
    }
}
