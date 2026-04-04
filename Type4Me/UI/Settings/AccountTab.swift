import SwiftUI

struct AccountTab: View, SettingsCardHelpers {
    @ObservedObject private var auth = CloudAuthManager.shared
    @ObservedObject private var quota = CloudQuotaManager.shared

    // Email login state
    @State private var email = ""
    @State private var codeSent = false
    @State private var verificationCode = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    // Anonymous login state
    @State private var anonUsername = ""
    @State private var anonPassword = ""
    @State private var anonIsLogin = false
    @State private var anonLoading = false
    @State private var anonError: String?

    var body: some View {
        if auth.isLoggedIn {
            loggedInView
        } else {
            loginView
        }
    }

    // MARK: - Login View

    @ViewBuilder
    private var loginView: some View {
        SettingsSectionHeader(
            label: "ACCOUNT",
            title: L("账户", "Account"),
            description: L(
                "登录后即可使用 Type4Me Cloud 语音识别和文本处理服务。",
                "Sign in to use Type4Me Cloud voice recognition and text processing."
            )
        )

        emailLoginCard

        Spacer().frame(height: 16)

        anonymousLoginCard
    }

    // MARK: - Email Login Card

    private var emailLoginCard: some View {
        settingsGroupCard(L("邮箱登录", "Email Login"), icon: "envelope.fill") {
            if codeSent {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.badge")
                            .foregroundStyle(TF.settingsAccentGreen)
                        Text(L("验证码已发送到 \(email)", "Code sent to \(email)"))
                            .font(.system(size: 12))
                            .foregroundStyle(TF.settingsTextSecondary)
                    }

                    HStack(spacing: 8) {
                        FixedWidthTextField(text: $verificationCode, placeholder: L("6 位验证码", "6-digit code"))
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .frame(maxWidth: 160)
                            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                        primaryButton(isLoading ? L("验证中...", "Verifying...") : L("验证", "Verify")) {
                            verifyCode()
                        }
                        .disabled(verificationCode.isEmpty || isLoading)

                        Button(L("重新发送", "Resend")) { sendCode() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TF.settingsTextSecondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text(L(
                    "免费体验 2000 字。",
                    "2000 characters free."
                ))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, 4)

                HStack(spacing: 8) {
                    FixedWidthTextField(text: $email, placeholder: L("邮箱", "Email"))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .frame(maxWidth: 260)
                        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                    primaryButton(isLoading ? L("发送中...", "Sending...") : L("发送验证码", "Send code")) {
                        sendCode()
                    }
                    .disabled(email.isEmpty || isLoading)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsAccentRed)
            }
        }
    }

    // MARK: - Anonymous Login Card

    private var anonymousLoginCard: some View {
        settingsGroupCard(L("匿名模式", "Anonymous Mode"), icon: "person.fill.questionmark") {
            Text(L(
                "不想提供邮箱？设置用户名和密码即可使用。",
                "Don't want to use email? Set a username and password."
            ))
            .font(.system(size: 12))
            .foregroundStyle(TF.settingsTextTertiary)
            .padding(.bottom, 4)

            HStack(spacing: 12) {
                Button(L("注册新账户", "Register")) {
                    anonIsLogin = false
                    anonError = nil
                }
                .foregroundStyle(anonIsLogin ? TF.settingsTextSecondary : TF.settingsText)

                Button(L("已有账户", "Log in")) {
                    anonIsLogin = true
                    anonError = nil
                }
                .foregroundStyle(anonIsLogin ? TF.settingsText : TF.settingsTextSecondary)
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.plain)
            .padding(.bottom, 4)

            HStack(spacing: 8) {
                FixedWidthTextField(text: $anonUsername, placeholder: L("用户名", "Username"))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .frame(maxWidth: 160)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                FixedWidthSecureField(text: $anonPassword, placeholder: L("密码 (至少6位)", "Password (6+ chars)"))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .frame(maxWidth: 200)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                primaryButton(
                    anonLoading
                        ? L("请等待...", "Please wait...")
                        : anonIsLogin ? L("登录", "Log in") : L("注册", "Register")
                ) {
                    anonIsLogin ? loginAnonymous() : registerAnonymous()
                }
                .disabled(anonUsername.isEmpty || anonPassword.count < 6 || anonLoading)
            }

            if let error = anonError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsAccentRed)
            }
        }
    }

    // MARK: - Actions

    private func sendCode() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await auth.sendCode(email: email)
                codeSent = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func verifyCode() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await auth.verify(email: email, code: verificationCode)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func registerAnonymous() {
        anonLoading = true
        anonError = nil
        Task {
            do {
                try await auth.registerAnonymous(username: anonUsername, password: anonPassword)
            } catch CloudAPIError.usernameTaken {
                anonError = L("用户名已被占用", "Username already exists")
            } catch {
                anonError = error.localizedDescription
            }
            anonLoading = false
        }
    }

    private func loginAnonymous() {
        anonLoading = true
        anonError = nil
        Task {
            do {
                try await auth.loginWithPassword(username: anonUsername, password: anonPassword)
            } catch {
                anonError = error.localizedDescription
            }
            anonLoading = false
        }
    }

    // MARK: - Logged In (placeholder for Task 9)

    @ViewBuilder
    private var loggedInView: some View {
        Text("TODO: logged in view")
    }
}
