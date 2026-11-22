# Локальная подпись OwnShot

Скрипт `scripts/create-signing-cert.sh` создаёт постоянный ключ подписи в локальной связке ключей. Отпечаток сертификата сохраняется в `.local-signing/identity.json`. Повторный запуск использует тот же ключ.

```sh
./scripts/create-signing-cert.sh
./scripts/build-ownshot.sh
```

По умолчанию собирается Release. Сборка проверяет подпись приложения и вложенных компонентов. После смены сертификата macOS может запросить разрешения повторно.

| Команда | Результат |
| --- | --- |
| `./scripts/build-ownshot.sh --install` | Собрать и установить в `~/Applications/OwnShot.app` |
| `./scripts/build-ownshot.sh --run` | Собрать, установить и запустить |
| `./scripts/build-ownshot.sh --configuration Debug` | Собрать для отладки |
| `./scripts/build-ownshot.sh --help` | Показать параметры сборки |
