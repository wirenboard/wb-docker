# Перепаковка и выпуск новой версии Docker

## Контекст

wb-docker-ce-repack производит набор из 4 пакетов на каждую связку (suite × arch):

- **`docker-ce`** — перепаковывается: внутрь добавляется WB-интеграция (overlay
  `daemon.json` + `postinst-snippet.sh`), к версии дописывается WB-суффикс
  `+wbNNN`.
- **`docker-ce-cli`, `containerd.io`, `docker-compose-plugin`** — зеркалируются
  как есть (тот же файл, та же версия). Лежат в репозитории WB ради
  самодостаточности: Docker ставится целиком из нашего репо, без подключения
  внешнего `download.docker.com`. docker-ce строго зависит от их точных версий,
  а внешний репозиторий Docker на контроллере не подключён.

Сборку и заливку в пул делает CI (jenkins-pipeline-lib → `buildDockerRepack`).
В этом репозитории лежат только манифест версий и тонкий `Jenkinsfile`.

## Файлы

| Файл | Назначение |
|---|---|
| `versions.env` | версии upstream + `WB_SUFFIX` + матрица suite/arch. Правится при каждом выпуске. |
| `Jenkinsfile` | точка входа CI, вызывает `buildDockerRepack`. |
| `repack/repack-docker-ce.sh` | механика: скачать upstream, перепаковать docker-ce, зеркалировать остальные 3. |
| `repack/overlay/` | файлы, инжектируемые внутрь docker-ce (шаблон `daemon.json` + systemd-drop-in для containerd). |
| `repack/preinst-snippet.sh` | метка установки: отличает `apt install` от обновления, инжектится в preinst docker-ce. |
| `repack/postinst-snippet.sh` | WB-setup (`/mnt/data`, симлинки, daemon.json, iptables-legacy). Инжектится в postinst docker-ce и ставится как `/usr/bin/wb-docker-setup` для осознанного ручного применения. |

## Как выпустить новую версию

1. Создать ветку.
2. Поправить `versions.env`:
   - обновить `DOCKER_CE_VERSION` / `CONTAINERD_VERSION` / `COMPOSE_VERSION`;
   - `WB_SUFFIX`: `+wb100` при новой upstream-версии Docker; `+wb101`, `+wb102…`
     если меняется только наша интеграция поверх той же версии Docker;
   - если новый Docker сломал интеграцию — поправить `repack/overlay/` и/или
     `repack/postinst-snippet.sh`.
3. Открыть PR. CI соберёт все пакеты, проверит и приложит артефакты к сборке.
   **В пул на этом этапе ничего не попадает.**
4. Поставить артефакты сборки на тестовый контроллер и проверить: `docker run
   --rm hello-world`, `docker compose version`, апгрейд поверх прошлой версии,
   апгрейд поверх `docker-ce` с download.docker.com (не должен менять ни
   `daemon.json`, ни `/etc/docker`, ни data-root), установку поверх удалённого
   через `apt remove` чужого `docker-ce` (настройка должна выполниться) и
   установку на хосте, где на
   `/mnt/data` остался стор containerd от прежней установки: реальный стор
   должен подхватиться, а уезжать в `.orphaned-<дата>` — только когда на rootfs
   есть свой стор с данными.
5. После ревью влить PR в `main`. CI пересоберёт и положит пакеты в пул. Дальше
   они попадают в testing по расписанию wb-releases (≈раз в час).

## Ручной запуск (без CI)

```bash
set -a; . ./versions.env; set +a
SUITE=trixie ARCH=arm64 bash repack/repack-docker-ce.sh
```

Готовые `.deb` появятся в `repack/artifacts/`. Установка на контроллер — см. `README.md`.
