# wb-docker-ce-repack

Инструмент сборки готовых пакетов Docker для контроллеров Wiren Board. Берёт
официальный Docker с download.docker.com и перепаковывает его так, чтобы на
контроллере он ставился и настраивался одной командой, без ручной донастройки.

## Зачем это нужно

Установка Docker на контроллер обычно требует ручной возни, а часть настроек на
WB нестандартна. Всё это встроено в установку пакета:

1. **Данные на постоянном разделе.** Обычный Docker кладёт данные в
   `/var/lib/docker` на rootfs — там мало места, и после перезагрузки образы и
   контейнеры пропадают. Пакет переносит data-root на `/mnt/data`.
2. **Сеть.** Для работы NAT контейнеров на WB нужен backend iptables-legacy —
   пакет включает его автоматически.
3. **Zero-config.** Симлинки, `daemon.json` и data-root выставляются на
   установке: после `apt install docker-ce` Docker готов к работе без
   какой-либо донастройки.

## Как производится перепаковка

Команда `apt install docker-ce` на WB-контроллере ставит сразу четыре пакета
(`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin`)
с WB-специфичной интеграцией, спрятанной внутрь `docker-ce`. Собираем мы её не
из исходников: берём готовые upstream-`.deb` с download.docker.com и делаем над
ними два шага.

### 1. Правим содержимое пакета

В скачанный `docker-ce.deb` **встраиваем свой код в установочный скрипт**
`postinst` — вставляем блок сразу после строки `set -e`, обёрнутый маркерами
`# --- BEGIN/END wb-docker setup ---` (родной код Docker остаётся нетронутым).
Симметрично в скрипт удаления `postrm` встраивается небольшой teardown-блок
(маркеры `# --- BEGIN/END wb-docker teardown ---`): при `apt purge docker-ce`
он останавливает `containerd` — чтобы ручная очистка данных на `/mnt/data`
(см. «Удалить») не выполнялась под работающим демоном — и убирает созданные
нами симлинки (висячий `/var/lib/containerd` ломал бы установку другого
containerd, например из `docker.io`). Данные на `/mnt/data` не трогаются.
Плюс кладём в пакет overlay-файлы — шаблон `daemon.json` и systemd-drop-in,
привязывающий старт `containerd` к монтированию `/mnt/data`, — и добавляем
`docker-compose-plugin` в зависимости `docker-ce`, чтобы один
`apt install docker-ce` тянул весь набор. Оригинальные упаковочные файлы Docker
(в том числе исходный `postinst`, в который мы инжектируем) лежат в
[docker/docker-ce-packaging](https://github.com/docker/docker-ce-packaging) —
удобно держать рядом при чтении `repack/repack-docker-ce.sh`.

Правим только `docker-ce`. Остальные три пакета (`docker-ce-cli`,
`containerd.io`, `docker-compose-plugin`) кладутся в WB-репо как есть —
побайтово upstream, тот же `Version`, то же имя файла. Они лежат в WB-репо ради
самодостаточности: Docker ставится целиком из репозитория WB, без подключения
внешнего `download.docker.com` (на контроллере его нет), а `docker-ce` строго
зависит от их точных версий.

### 2. Проставляем WB-суффикс к версии

Апстримный `docker-ce.deb` с download.docker.com уже приходит с полной версией
вида `5:29.5.2-1~debian.13~trixie` — всё в ней задаёт сам Docker: эпоха `5:`
(у Docker с 2017 года), номер ревизии `-1` и целевой Debian `~debian.13~trixie`.
Мы **дописываем к ней только WB-суффикс `+wb1xx`** и больше ничего:

```
5:29.5.2-1~debian.13~trixie      ← версия из репозитория Docker (как есть)
5:29.5.2-1~debian.13~trixie+wb101 ← что кладём в WB-репо (добавили +wb101)
```

- `+wb100` — первый выпуск под новую upstream-версию Docker;
- `+wb101`, `+wb102`… — правки нашей интеграции (`postinst`/overlay) поверх той
  же версии Docker.

Суффикс `+wb1xx` дописывается **только** к `docker-ce` (три зеркалируемых пакета
идут с неизменной upstream-версией). Актуальные upstream-версии — в
[release notes Docker Engine](https://docs.docker.com/engine/release-notes/).

## Структура репозитория

Весь код сборки лежит в одном каталоге `repack/` в корне репозитория — это
единственная рабочая директория проекта: скрипт перепаковки, инжектируемые в
`docker-ce` артефакты (overlay и postinst-сниппет) и кэш/выход сборки.

```
repack/
├── repack-docker-ce.sh     — главный скрипт сборки
├── postinst-snippet.sh     — WB-setup, инжектится в docker-ce DEBIAN/postinst
├── postrm-snippet.sh       — WB-teardown, инжектится в docker-ce DEBIAN/postrm
├── overlay/                — файлы, инжектящиеся в дерево docker-ce.deb
│   ├── usr/share/wb-docker/daemon.json                       — шаблон daemon.json (data-root на /mnt/data)
│   └── etc/systemd/system/containerd.service.d/mnt-data.conf — containerd стартует после монтирования /mnt/data
├── src/                    — кэш upstream .deb (gitignored)
├── out/                    — распакованные stage-каталоги (gitignored)
└── artifacts/              — собранные .deb (gitignored)
```

## Быстрый старт

### Собрать пакеты на своей машине

Требуется Linux с `wget`, `dpkg-deb`, `md5sum`, `tar`
(или на macOS — `brew install wget dpkg coreutils`; coreutils ставит `gmd5sum`,
скрипт сборки подхватывает его автоматически).

```bash
# Без SUITE/ARCH берёт trixie/armhf (дефолты скрипта); версии — из versions.env
bash repack/repack-docker-ce.sh

# Или явно задать suite и архитектуру:
SUITE=trixie ARCH=arm64 bash repack/repack-docker-ce.sh
SUITE=trixie ARCH=armhf bash repack/repack-docker-ce.sh
```

Готовые `.deb` появятся в `repack/artifacts/`.

### Поставить на тестовый контроллер

С локальной машины скопировать четыре `.deb` на контроллер:

```bash
HOST=wirenboard-XXXXXXXX.local       # серийник контроллера, 8 символов
ARCH=arm64                            # arm64 для wb8, armhf для wb6/wb7

scp repack/artifacts/*_${ARCH}.deb root@${HOST}:/tmp/
```

На контроллере поднять локальный apt-репозиторий и поставить:

```bash
mkdir -p /var/local/wb-repo
mv /tmp/*.deb /var/local/wb-repo/
cd /var/local/wb-repo
apt-ftparchive packages . > Packages && gzip -k -f Packages

cat > /etc/apt/sources.list.d/wb-local.list <<EOF
deb [trusted=yes] file:/var/local/wb-repo ./
EOF

apt-get update
apt-get install -y docker-ce          # одной командой все четыре пакета
```

Проверить, что всё поднялось:

```bash
docker info 2>&1 | grep 'Docker Root Dir'      # → /mnt/data/docker/lib
docker compose version
docker run --rm hello-world
```

### Удалить

Пакет намеренно не удаляет данные: данные, конфиги и `daemon.json` живут на
`/mnt/data` и переживают `apt purge` и переустановку. Наш postrm при purge
делает два действия: останавливает `containerd` (см. ниже, почему это важно)
и убирает WB-симлинки `/var/lib/containerd` и `/etc/docker` (сам `/etc/docker`
обычно снимает dpkg — путь принадлежит пакету). Цели симлинков на `/mnt/data`
не трогаются, переустановка всё пересоздаёт. Полную очистку данных делают
вручную (см. ниже).

Штатное удаление (с сохранением пользовательских данных на `/mnt/data`):

```bash
apt purge docker-ce && apt autoremove --purge
```

Полное удаление вместе с образами и контейнерами:

```bash
apt purge docker-ce docker-ce-cli containerd.io docker-compose-plugin
apt autoremove --purge
rm -rf /mnt/data/docker /mnt/data/.docker /mnt/data/etc/docker \
       /mnt/data/var/lib/containerd
[ ! -L /var/lib/containerd ] || rm /var/lib/containerd
```

Последняя строка — для установок со старыми версиями пакета, чей postrm ещё
не убирал симлинк: оставшийся висячим `/var/lib/containerd` ломает установку
другого containerd (например, из `docker.io` — тот падает в рестарт-цикле на
`mkdir: file exists`). Удаляется именно симлинк; на свежих версиях его уже
снял postrm, и строка ничего не делает.

Здесь все четыре пакета перечислены явно — на `apt autoremove` полагаться
нельзя: он убирает только пакеты с пометкой automatic, а после установки из
локальных `.deb` (или явного `apt install containerd.io`) они помечены manual
и остаются. Критично, что prerm `containerd.io` останавливает демона **до**
`rm -rf`: удалять данные из-под работающего containerd нельзя — он держит
удалённые файлы метаданных открытыми и продолжает отдавать «призрачное»
состояние (pull «проходит» без скачивания, после перезапуска демона —
`blob not found`). Свежие версии пакета дополнительно страхуют это в postrm
(purge `docker-ce` сам останавливает containerd), но на установках со старыми
версиями действует их старый postrm — команда выше безопасна на любых.

## Переход со старого Docker

«Старый» здесь — любой Docker не из этой WB-сборки: `docker.io` из Debian или
`docker-ce` напрямую с download.docker.com. Его образы и контейнеры лежат в
`/var/lib/docker` на rootfs (уже установленный WB Docker сюда не попадает — он
держит данные на `/mnt/data`). Перенести их в WB Docker автоматически нельзя.
Причин две:

- WB Docker держит data-root на `/mnt/data` (`/mnt/data/docker/lib`), а прежний
  Docker — в `/var/lib/docker` на rootfs;
- Docker 29 по умолчанию использует containerd image store, который не читает
  старый overlay2-стор: такие образы становятся невидимы (`docker images` пуст),
  хотя данные остаются на диске.

Docker не умеет надёжно мигрировать стор между версиями. Единственный надёжный
путь — **до установки** WB Docker выгрузить нужные образы на старом Docker:

```bash
docker save my-image:tag -o /mnt/data/my-image.tar   # или docker push в registry
```

и после установки загрузить обратно:

```bash
docker load -i /mnt/data/my-image.tar
```

Данные в томах (`/var/lib/docker/volumes`) `docker save` не покрывает —
бэкапьте их отдельно. Установка WB Docker прежний `/var/lib/docker` не удаляет:
при установке в лог `apt` выводится предупреждение, а данные остаются на диске и
их можно забрать вручную.

## Сборка в CI

Сборкой занимается Jenkins-джоба
[wirenboard/wb-docker-ce-repack](https://jenkins.wirenboard.com/job/wirenboard/job/wb-docker-ce-repack/):
она запускается на каждый push и PR. Локальный `Jenkinsfile` — однострочный
вызов `buildDockerRepack()`, вся логика пайплайна живёт в shared-библиотеке
jenkins-pipeline-lib:
[vars/buildDockerRepack.groovy](https://github.com/wirenboard/jenkins-pipeline-lib/blob/master/vars/buildDockerRepack.groovy).

## Полная документация

- Краткая операционная инструкция по перепаковке новой версии —
  [Перепаковка Docker для Wiren Board](https://docs.google.com/document/d/1SS1GXR9tSsovYjIU3ILNvEqS7ZJKOOznjiLtqoGcz34/edit?tab=t.0)
  (Google Drive).
- Архитектура и обоснования решений —
  [Архитектура и решения по перепаковке Docker](https://docs.google.com/document/d/1euyEGmuH-pTFkhabeNXJLJFl5f-1zrSwjaRvOHXki2g/edit)
  (Google Drive).

## Ссылки

- Документация по WB Docker: https://wiki.wirenboard.com/wiki/Docker
- Community installer: https://github.com/wirenboard/wb-community/blob/main/scripts/docker-install/wb-docker-manager.sh
- WB apt repo: https://deb.wirenboard.com
- WB Jenkins: https://jenkins.wirenboard.com
