import SwiftUI

/// 登录界面：手机号 + 短信验证码。
///
/// 对应原 APK 中文文案：
/// `登录哪吒汽车`、`请输入手机号`、`请输入正确的手机号`、`获取验证码`、
/// `验证码已发送`、`正在查询结果`、`重新获取验证码`、`登录失败`、
/// `登录已过期`、`退出登录`
struct LoginView: View {

    /// 登录成功回调。未传则成功后自行 dismiss。
    var onSuccess: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LoginModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header

                VStack(spacing: 14) {
                    phoneField
                    codeField
                    actionButton
                }
                .padding(.horizontal)

                if let message = model.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(model.isError ? .red : .secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.isLoggedIn {
                        Button("退出登录") { model.logout() }
                            .foregroundStyle(.red)
                    } else if onSuccess == nil {
                        Button("取消") { dismiss() }
                    }
                }
            }
        }
        .onAppear { model.onSuccess = onSuccess }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "car.side.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("哪吒汽车")
                .font(.title2.weight(.medium))
            Text("登录后管理车辆与车控")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var phoneField: some View {
        HStack {
            Text("+86").foregroundStyle(.secondary)
            TextField("请输入手机号", text: $model.phone)
                .keyboardType(.numberPad)
                .textContentType(.telephoneNumber)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var codeField: some View {
        HStack {
            TextField("位验证码", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)

            Button {
                model.requestCode()
            } label: {
                Text(model.countdown > 0 ? "\(model.countdown)秒后重发" : "获取验证码")
                    .font(.caption)
                    .foregroundStyle(model.countdown > 0 ? .secondary : Color.accentColor)
            }
            .disabled(model.countdown > 0 || !model.isPhoneValid)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var actionButton: some View {
        Button {
            model.login()
        } label: {
            HStack {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Text(model.isLoading ? "正在查询结果" : "登录")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isLoading || !model.isPhoneValid || model.code.isEmpty)
    }
}

@MainActor
final class LoginModel: ObservableObject {

    /// 登录成功回调，由 View 注入
    var onSuccess: (() -> Void)?

    @Published var phone = ""
    @Published var code = ""
    @Published var countdown = 0
    @Published var isLoading = false
    @Published var statusMessage: String?
    @Published var isError = false
    @Published var isLoggedIn = false

    private var countdownTask: Task<Void, Never>?

    var isPhoneValid: Bool {
        AuthService.isValidPhone(phone)
    }

    // MARK: 验证码

    func requestCode() {
        guard isPhoneValid else {
            show("请输入正确的手机号", error: true)
            return
        }

        countdown = 60
        startCountdown()

        Task {
            do {
                try await AuthService.shared.requestSMSCode(phone: phone)
                show("验证码已发送", error: false)
            } catch {
                show(error.localizedDescription, error: true)
                countdown = 0
            }
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while let s = self, s.countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self?.countdown -= 1
            }
        }
    }

    // MARK: 登录

    func login() {
        guard isPhoneValid else {
            show("请输入正确的手机号", error: true)
            return
        }
        guard !code.isEmpty else {
            show("请先获取验证码", error: true)
            return
        }

        isLoading = true
        statusMessage = nil

        Task {
            do {
                try await AuthService.shared.login(phone: phone, code: code)
                isLoading = false
                isLoggedIn = true
                show("登录成功", error: false)
                onSuccess?()
            } catch {
                isLoading = false
                show(error.localizedDescription, error: true)
            }
        }
    }

    func logout() {
        Task {
            await AuthService.shared.logout()
            isLoggedIn = false
            code = ""
            show("已退出登录", error: false)
        }
    }

    private func show(_ message: String, error: Bool) {
        statusMessage = message
        isError = error
    }

    deinit { countdownTask?.cancel() }
}