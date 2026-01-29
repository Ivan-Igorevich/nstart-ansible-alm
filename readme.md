# Ansible Nexus Repository Manager 3 Provisioning
Автоматизированная установка и конфигурация Sonatype Nexus Repository Manager 3 с поддержкой:

- Blob stores (os, dev, docker, llm)
- Репозиториев (npm, pypi, maven, nuget и др.)
- Гибкого управления через библиотеку репозиториев
- Идемпотентных операций очистки и развёртывания

## Структура проекта
```
.
├── ansible.cfg                 # Настройки Ansible (vault, inventory)
├── inventory.ini               # Инвентарь хостов
├── main.yml                    # Основной playbook
├── docker-compose.yml          # Конфигурация Docker Compose
├── nginx.conf                  # Конфигурация Nginx reverse proxy
├── .gitignore
│
├── group_vars/nexus_servers/  # Переменные для группы nexus_servers
│   ├── connection.yml         # URL, пользователь, SSL
│   ├── blobstores.yml         # Список blob stores
│   ├── repo_library.yml       # Полная библиотека репозиториев
│   ├── repo_active.yml        # Списки репозиториев для создания/удаления
│   └── vault.yml              # Зашифрованный пароль администратора
│
└── roles/
    ├── nexus-purge/           # Полная очистка данных Nexus
    ├── nexus-bootstrap/       # Установка и первоначальная настройка
    └── nexus/                 # Конфигурация после установки
        └── tasks/
            ├── main.yml
            ├── blobstores.yml
            ├── clean_repositories.yml
            ├── repo_npm.yml
            ├── repo_pypi.yml
            └── repo_maven.yml 
```

## Быстрый старт
1. Подготовка

- Убедитесь, что установлены: `ansible`, `docker`, `docker-compose`
- Создайте файл ~/.ansible-vault-pass.txt с паролем для vault

2. Полная установка с нуля

```bash
# Очистить всё (с потерей всех данных) и установить Nexus
ansible-playbook main.yml --tags purge,boot

# Настроить blob stores и репозитории
ansible-playbook main.yml --tags configure
```

## Управление репозиториями
### Библиотека репозиториев
Файл `repo_library.yml` содержит полную библиотеку всех возможных репозиториев с их параметрами.
Пример:

```yaml
npm-proxy:
  format: "npm"
  type: "proxy"
  blob_store: "dev"
  remote_url: "https://registry.npmjs.org/"
```
### Активные репозитории
Файл `repo_active.yml` определяет, какие репозитории развёртывать:

```yaml
nexus_active_repositories:
  - "npm-proxy"
  - "npm-hosted"
  - "pypi-proxy"

nexus_repositories_to_delete:
  - "old-repo"
```
### «Форматы — каждый со своим тегом»:
```yaml
- name: Configure NPM repositories
  include_tasks: npm.yml
  tags: [configure, npm]

- name: Configure PyPI repositories
  include_tasks: pypi.yml
  tags: [configure, pypi]

- name: Configure Maven repositories
  include_tasks: maven.yml
  tags: [configure, maven]
```

## Безопасность
Пароль администратора хранится в `vault.yml` (зашифрован через `ansible-vault`).
Все чувствительные данные исключены из репозитория с помощью`.gitignore`.
Для запуска требуется файл `~/.ansible-vault-pass.txt` с паролем от `vault`

## Теги Ansible
| Тег | Действие |
|:----|----------|
| purge | Полная очистка данных Nexus и контейнеров |
| bootstrap | Установка Nexus, настройка пароля, анонимный доступ |
| configure | Полная конфигурация (blob stores, репозитории) |
| clean | Удаление репозиториев из nexus_repositories_to_delete |
| repositories | Создание репозиториев из nexus_active_repositories |

## Примечания
- Проект разработан для Nexus Repository Manager 3.80+
- Поддерживает HTTPS через Nginx reverse proxy
- Все пути к данным локальные (`./nexus-data`)
- Для `production` рекомендуется настроить TLS и внешние blob stores