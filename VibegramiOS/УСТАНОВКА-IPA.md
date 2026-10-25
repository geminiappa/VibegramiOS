# Vibegram IPA: сборка и установка

## Где забрать файл

1. В GitHub открой `Actions` → `Build Vibegram IPA`.
2. Запусти workflow через `Run workflow` или дождись автоматического запуска после commit.
3. Открой завершившийся запуск с зелёной галочкой.
4. В секции `Artifacts` скачай `Vibegram-unsigned-IPA.zip`.
5. Распакуй этот внешний ZIP. Внутри должен быть `Vibegram-unsigned.ipa`.

Не переименовывай внешний `Vibegram-unsigned-IPA.zip` в `.ipa` — это не сам IPA.

## Важно про подпись

Workflow создаёт **неподписанный** IPA. iOS не позволит установить его нажатием в «Файлах» или Safari. Нужно импортировать именно `Vibegram-unsigned.ipa` в AltStore Classic, SideStore или Sideloadly — программа подпишет его для твоего устройства с помощью Apple ID. Сам архив не содержит сертификат или provisioning profile.

## Проверки в workflow

Workflow собирает device-версию через `iphoneos` с `ARCHS=arm64`, проверяет `Info.plist`, `CFBundleExecutable`, `CFBundleIdentifier`, архитектуру главного бинарника и стандартный путь `Payload/Vibegram.app` внутри IPA.

Если установка всё равно не проходит, пришли точный текст ошибки из AltStore/SideStore/Sideloadly. Без него нельзя надёжно определить, проблема ли это подписи, формата архива или несовместимости iOS.
