# Собрать IPA для Sideloadly без Mac

В этой среде нет macOS/Xcode, поэтому настоящий iOS-бинарник нельзя скомпилировать прямо здесь. Workflow в `.github/workflows/build-ipa.yml` соберёт проект на macOS runner GitHub Actions и приложит unsigned IPA как скачиваемый artifact.

## Как получить IPA с Windows

1. Создай отдельный репозиторий GitHub, например `VibegramiOS`.
2. Распакуй этот архив и загрузи **все файлы и папки из корня проекта**, включая скрытую папку `.github`, в корень репозитория. Не загружай только ZIP-файл.
3. Сделай commit/push в ветку `main` (или `master`). Workflow автоматически запустится. Либо открой вкладку **Actions → Build Vibegram IPA → Run workflow**.
4. Открой завершённый запуск, найди **Artifacts** и скачай `Vibegram-unsigned-IPA`. Это ZIP с файлом `Vibegram-unsigned.ipa` внутри.
5. Распакуй скачанный artifact, открой Sideloadly на Windows, подключи iPhone по USB и перетащи `Vibegram-unsigned.ipa` в Sideloadly. Введи Apple ID непосредственно в Sideloadly и начни установку.

## Важное

- IPA будет **unsigned**; Sideloadly подпишет его для твоего устройства. iOS не запускает неподписанные приложения напрямую.
- Не передавай Apple ID, пароль или коды подтверждения мне и не сохраняй их в GitHub Actions secrets. Вводи Apple ID только в официальное приложение Sideloadly.
- Бесплатная подпись Apple ID обычно требует повторной установки/обновления подписи периодически (часто через 7 дней). См. официальные сведения Sideloadly.
- В проекте используется Bundle ID `com.vibegram.messenger`; если он уже занят или Sideloadly попросит изменить его, используй уникальный Bundle ID.
- Никакая GitHub-сборка не запускается сама, пока ты не загрузишь проект в свой репозиторий. Содержимое сайта продолжит загружаться с `https://vibegramm.onrender.com`.
