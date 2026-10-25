# Vibegram для iOS

Нативная оболочка iOS на SwiftUI + WKWebView для существующего Vibegram: `https://vibegramm.onrender.com`.

## Что есть

- SwiftUI-экран запуска в тёмном стиле Vibegram и значок приложения.
- Открывает тот же сайт и сервер, поэтому сообщения/профили синхронизируются с веб-версией через существующий backend.
- Поддерживает жест назад/вперёд в WKWebView и обновление страницы свайпом вниз.
- Отображает сетевой экран с кнопками повтора и открытия в Safari.
- Внешние HTTPS-ссылки открывает в Safari; `mailto:`, `tel:` и `sms:` передаёт соответствующим приложениям.
- Прописаны системные разрешения для камеры, микрофона и фототеки, чтобы сайт мог запросить доступ при отправке фото/видео или записи голоса.
- Включён базовый `PrivacyInfo.xcprivacy` без заявленного сбора данных самим контейнером.

## Как открыть и запустить

1. На Mac установи Xcode 15 или новее.
2. Распакуй папку `VibegramiOS`.
3. Открой `Vibegram.xcodeproj`.
4. В Xcode выбери схему **Vibegram** и iPhone Simulator.
5. Нажми Run.
6. Чтобы запустить на реальном iPhone, подключи устройство, выбери его и в **Signing & Capabilities** выбери свою Apple ID / Development Team. При необходимости замени Bundle Identifier `com.vibegram.messenger` на уникальный.

## Перед публикацией в App Store

Этот первый iOS-проект показывает текущую веб-версию внутри нативной оболочки; он не переносит веб-код в нативные экраны. Поэтому синхронизация зависит от работоспособности сайта и сервера. Перед публичной публикацией нужно проверить требования App Review, доступность сайта, тексты политики конфиденциальности и поведение входа.

**Push-уведомления APNs в этой версии ещё не подключены.** Для доставки уведомлений, когда приложение закрыто, нужны Apple Developer Team, APNs key/capabilities, регистрация device token и серверная отправка push через APNs. Разрешения Web Notifications внутри обычного WKWebView не заменяют APNs.

## Файлы

- `Vibegram/VibegramApp.swift` — точка входа.
- `Vibegram/ContentView.swift` — загрузочный экран, состояние сети и повтор.
- `Vibegram/VibegramWebView.swift` — WKWebView, навигация и pull-to-refresh.
- `Vibegram/Assets.xcassets` — значок и брендовая графика.

## Получить IPA для Sideloadly без Mac

В корне проекта есть workflow `.github/workflows/build-ipa.yml`, который собирает unsigned IPA на GitHub Actions (macOS). Инструкция: [`BUILD_IPA_FOR_SIDELOADLY.md`](BUILD_IPA_FOR_SIDELOADLY.md). Загрузка IPA прямо из этой Linux-среды невозможна, поскольку здесь нет Xcode/iOS SDK.
