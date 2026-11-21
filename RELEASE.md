# Выпуски Branchline

Первый публичный выпуск — **1.0.0**, внутренний номер сборки — **14**. Образ содержит нативные версии для Apple Silicon и Intel и требует macOS 14 или новее.

## Подготовка GitHub

1. Включите GitHub Pages. В **Settings → Pages → Build and deployment → Source** выберите **GitHub Actions**.
2. Создайте окружение **macos-release** и ограничьте его веткой по умолчанию. Добавьте в него секреты из таблицы. Экспортируйте сертификат **Developer ID Application** вместе с приватным ключом в PKCS#12. Для нотарификации используйте командный ключ App Store Connect API.
3. Создайте отдельную пару EdDSA-ключей для Branchline. Сохраните резервную копию приватного ключа и предоставьте доступ к нему только владельцам выпуска. Один публичный ключ должен использоваться всеми стабильными сборками этого канала.

| Ключ | Где хранить | Значение |
| --- | --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Secret окружения | Файл Developer ID Application `.p12` в Base64 |
| `DEVELOPER_ID_P12_PASSWORD` | Secret окружения | Пароль файла `.p12` |
| `NOTARY_P8_BASE64` | Secret окружения | Файл ключа App Store Connect `.p8` в Base64 |
| `NOTARY_KEY_ID` | Secret окружения | ID ключа App Store Connect |
| `NOTARY_ISSUER_ID` | Secret окружения | Issuer ID ключа App Store Connect |
| `BRANCHLINE_SPARKLE_PRIVATE_KEY` | Secret окружения | Содержимое файла, экспортированного `generate_keys -x` |
| `BRANCHLINE_SPARKLE_PUBLIC_KEY` | Variable окружения | Публичный ключ Sparkle в Base64 |
| `BRANCHLINE_PAGES_URL` | Variable репозитория, опционально | Базовый HTTPS-адрес страницы, если используется свой домен или нестандартный путь |

Для Sparkle после первой сборки используйте инструменты закреплённой версии. При стандартной сборке универсального приложения они находятся в `.build/package-arm64/artifacts/sparkle/Sparkle/bin`.

```sh
tools=".build/package-arm64/artifacts/sparkle/Sparkle/bin"
"$tools/generate_keys" --account branchline-stable
"$tools/generate_keys" --account branchline-stable -p
```

Экспортируйте приватный ключ с `generate_keys --account branchline-stable -x /путь/вне/репозитория`. Передайте его в **Actions → Secrets** через защищённый интерфейс GitHub. Изменение ключа или адреса подписанной ленты требует отдельного плана миграции для уже установленных копий. [Документация Sparkle](https://sparkle-project.org/documentation/)

## Выпуск

1. Увеличьте `CFBundleShortVersionString` и `CFBundleVersion` в `Scripts/Info.plist`. Номер сборки должен расти с каждым публичным выпуском. Добавьте описание в `ReleaseNotes/<version>.md`.
2. После проверок влейте изменения в ветку по умолчанию. Запустите **Actions → macOS release → Run workflow**. Оставьте `publish` выключенным для проверки универсальной сборки без подписи Developer ID. Включите его для стабильного выпуска.
3. Публикация начнётся после проверки Developer ID, нотарификации и подписи обновления. В GitHub Releases появится тег `v<version>` и файлы DMG, ZIP для Sparkle, подписанная лента и контрольные суммы SHA-256. Затем одна сборка GitHub Pages опубликует страницу, подписанный `appcast.xml` и данные кнопки скачивания из того же релиза.

Если выпуск появился в GitHub Releases, а обновление Pages завершилось ошибкой, повторно запустите **Download page**. Она возьмёт уже опубликованные файлы. Для отката исправьте проблему и выпустите следующую сборку с большим `CFBundleVersion`, чтобы установленные копии получили её как обновление.

## Локальная проверка

```sh
Scripts/release.sh --dry-run dist/release OWNER/branchline
Scripts/package.sh dist/test --dmg
```

Тестовый образ использует локальную ad-hoc подпись. У него отключён канал обновлений. Для выпуска на своей машине потребуются `BRANCHLINE_SIGNING_IDENTITY`, `BRANCHLINE_NOTARY_PROFILE`, `BRANCHLINE_SPARKLE_PUBLIC_KEY` и `BRANCHLINE_SPARKLE_PRIVATE_KEY`. Подготовьте профиль через `xcrun notarytool store-credentials` и запустите `Scripts/release.sh dist/release OWNER/branchline`. Скрипт выполняет сборку и проверку артефактов, а GitHub Actions публикует их. [Нотарификация Apple](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Проверьте публичный образ на другом Mac с обычными настройками Gatekeeper. Установите его в «Программы» и убедитесь, что он открывается. Для проверки обновления установите предыдущую подписанную сборку и выберите обновление из приложения. Уточните версию после перезапуска и проверьте восстановление вкладок, черновика сообщения и открытого репозитория.
