import SwiftUI
import WebKit

struct ContentView: View {
    private let homeURL = URL(string: "https://vibegramm.onrender.com")!

    @State private var webView: WKWebView?
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var hasError = false
    @State private var showSafari = false

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.045, blue: 0.085)
                .ignoresSafeArea()

            VibegramWebView(
                url: homeURL,
                webView: $webView,
                isLoading: $isLoading,
                hasLoaded: $hasLoaded,
                hasError: $hasError
            )
            .opacity(hasLoaded || hasError ? 1 : 0.02)
            .accessibilityLabel("Vibegram messenger")

            if !hasLoaded && isLoading && !hasError {
                LoadingScreen()
                    .transition(.opacity)
                    .zIndex(2)
            }

            if hasError && !hasLoaded {
                NetworkErrorScreen(
                    retry: loadHome,
                    openInSafari: { showSafari = true }
                )
                .zIndex(3)
            }
        }
        .animation(.easeOut(duration: 0.2), value: hasLoaded)
        .animation(.easeOut(duration: 0.2), value: hasError)
        .sheet(isPresented: $showSafari) {
            SafariView(url: homeURL)
                .ignoresSafeArea()
        }
        .onChange(of: showSafari) { isPresented in
            if !isPresented, !hasLoaded {
                loadHome()
            }
        }
        .statusBarHidden(false)
    }

    private func loadHome() {
        hasError = false
        isLoading = true
        if let webView {
            webView.load(URLRequest(url: homeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
    }
}

private struct LoadingScreen: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.045, blue: 0.10), Color(red: 0.08, green: 0.08, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.43, green: 0.29, blue: 1), Color(red: 0.12, green: 0.57, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 92, height: 92)
                        .shadow(color: Color.blue.opacity(0.28), radius: 24, y: 8)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(-10))
                        .offset(x: -2, y: 1)
                }

                VStack(spacing: 5) {
                    Text("Vibegram")
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Общайся. Создавай. Развивайся.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.64))
                }

                ProgressView()
                    .tint(.white.opacity(0.88))
                    .padding(.top, 8)
                    .accessibilityLabel("Загрузка Vibegram")
            }
            .padding(28)
        }
    }
}

private struct NetworkErrorScreen: View {
    let retry: () -> Void
    let openInSafari: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.045, blue: 0.085).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(Color(red: 0.55, green: 0.48, blue: 1))
                    .padding(.bottom, 4)
                Text("Не удалось подключиться")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Проверь интернет-соединение и попробуй снова. Сообщения и профиль загружаются с сервера Vibegram.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: retry) {
                    Label("Повторить", systemImage: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(LinearGradient(colors: [Color(red: 0.40, green: 0.30, blue: 1), Color(red: 0.16, green: 0.46, blue: 1)], startPoint: .leading, endPoint: .trailing))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                Button("Открыть в Safari", action: openInSafari)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: 420)
        }
    }
}
