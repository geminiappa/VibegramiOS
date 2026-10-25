# Сборка Vibegram IPA через GitHub Actions

1. Загрузите **содержимое** папки `VibegramiOS` в корень GitHub-репозитория (так, чтобы `Vibegram.xcodeproj` находился в корне).
2. Убедитесь, что загружен файл `.github/workflows/build-ipa.yml`. В браузерном интерфейсе GitHub создайте его по пути `.github/workflows/build-ipa.yml`, если скрытая папка не была загружена.
3. Откройте **Actions → Build Vibegram IPA → Run workflow**. Автоматически также запускается при push изменений Swift/Xcode в ветку `main` или `master`.
4. Когда workflow завершится зелёным, откройте конкретный запуск и скачайте артефакт `Vibegram-unsigned-IPA` внизу страницы.
5. Распакуйте ZIP с артефактом, чтобы получить `Vibegram-unsigned.ipa`.
6. Импортируйте неподписанный IPA в инструмент sideloading, который вы выбрали, и подпишите его собственным Apple ID / сертификатом.

Workflow ищет `Vibegram.xcodeproj` в репозитории, проверяет shared scheme `Vibegram`, собирает Release для generic iOS device, проверяет `Info.plist` и формирует ZIP-структуру `Payload/Vibegram.app`.

**Примечание:** CI создаёт неподписанный IPA, а не App Store-сборку. На iPhone требуется действительная подпись. Успешность компиляции нужно подтверждать по результату Actions: среда разработки вне macOS не содержит Xcode и не может выполнить финальную сборку локально.
