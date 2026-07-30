# Dev Environment Setup

![Shell](https://img.shields.io/badge/shell-bash-1f425f?logo=gnu-bash)
![Ubuntu](https://img.shields.io/badge/Ubuntu-26.04%20%7C%2024.04%20%7C%2022.04-E95420?logo=ubuntu&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

Script único de bootstrap para configurar uma máquina Ubuntu (**26.04 "Resolute"**, com fallback para **24.04** e **22.04**) com toda a stack de desenvolvimento: PHP, Java/Maven, Python, Node (via NVM)/Yarn, clientes de banco de dados, Kubernetes, Terraform, AWS CLI, configuração de Git/locale/timezone e assistentes de IA via CLI (Claude Code, Codex, Kiro, OpenCode).

## Índice

- [O que o script instala](#o-que-o-script-instala)
- [Requisitos](#requisitos)
- [Uso](#uso)
- [Idempotência](#idempotência)
- [Notas específicas do Ubuntu 26.04](#notas-específicas-do-ubuntu-2604)
- [Estrutura do script](#estrutura-do-script)
- [Licença](#licença)

## O que o script instala

| Categoria | Ferramentas |
|---|---|
| **Base** | curl, git, vim, nano, unzip, zip, jq, dos2unix, gnupg, build-essential, fontes (Fira Code) |
| **PHP** | PHP 8.4 e 8.5 (via repositório Sury), extensões comuns (gd, mysql, curl, intl, mbstring, redis, etc.), Composer, Laravel Installer |
| **Java** | OpenJDK 25 (JDK), Apache Maven, `JAVA_HOME` configurado no bash/zsh |
| **Python** | Python 3 (versão padrão do Ubuntu), pip, venv, python3-dev, pipx |
| **Shell** | Zsh + Oh My Zsh, plugins (autosuggestions, completions, nvm, F-Sy-H), tema Dracula |
| **Node** | NVM, Node.js (última versão LTS), Yarn (repositório oficial) |
| **Bancos de dados** | Clientes `mysql-client`, `postgresql-client`, `redis-tools` |
| **Kubernetes** | kubectl, Helm, kubectx/kubens, hetzner-k3s, hcloud CLI |
| **Cloud** | AWS CLI v2, AWS Session Manager Plugin, Terraform (repositório HashiCorp) |
| **CLIs de IA** | GitHub CLI (gh), Claude Code CLI, Codex CLI (OpenAI), Kiro CLI, OpenCode CLI |
| **Sistema** | Locales `en_US.UTF-8`/`pt_BR.UTF-8`, sincronização de horário via NTP, `apt` não interativo (`DEBIAN_FRONTEND=noninteractive`) |
| **Git** | Defaults (`init.defaultBranch=main`, `pull.rebase=false`, `core.editor=code --wait` se o VS Code estiver disponível, senão `nano`); pede `user.name`/`user.email` se a execução for interativa |
| **Extras** | Chave SSH (ed25519), aliases de Kubernetes/Helm, integração com direnv |

## Requisitos

- Ubuntu 26.04 LTS (Resolute) — também funciona em 24.04 (Noble) e 22.04 (Jammy)
- Acesso `sudo` (ou execução como `root`)
- Conexão com a internet

## Uso

```bash
chmod +x setup.sh
./setup.sh
```

Pode ser executado tanto diretamente como usuário comum com `sudo` disponível quanto via `sudo ./setup.sh`. O script detecta automaticamente o usuário alvo (via `$SUDO_USER`) e aplica as configurações de shell/SSH/CLIs nesse usuário, não em `root`.

Depois de rodar, abra um novo terminal (ou rode `exec zsh`) para carregar as alterações de shell (PATH, plugins, aliases, `JAVA_HOME`, NVM).

Se o terminal for interativo (TTY disponível) e o Git ainda não tiver `user.name`/`user.email` configurados globalmente, o script pergunta esses dados durante a execução. Em execuções não interativas (CI, cloud-init, `curl | bash`), essa etapa é pulada com um aviso (`[WARN]`) e pode ser configurada depois manualmente.

## Idempotência

O script é seguro para rodar múltiplas vezes: cada etapa verifica se a ferramenta/repositório já está presente antes de instalar novamente.

## Notas específicas do Ubuntu 26.04

- O repositório oficial de PHP (`packages.sury.org`) e o da HashiCorp já publicam pacotes nativos para o codename `resolute`. Caso um repositório de terceiros ainda não tenha suporte publicado para uma versão muito recente do Ubuntu, o script cai automaticamente para o codename `noble` (24.04), que é binário-compatível.
- Algumas extensões PHP mais novas (ex.: `redis`, `imap` para PHP 8.4/8.5) podem ainda não estar disponíveis para Ubuntu no repositório Sury em determinados momentos. O script detecta pacotes indisponíveis, avisa no log (`[WARN]`) e segue em frente sem travar a instalação.
- O `openjdk-25-jdk` e o `maven` vêm dos repositórios oficiais do Ubuntu (`main`/`universe`). Em versões mais antigas (22.04/24.04), o script habilita o repositório `universe` automaticamente; se o pacote ainda não tiver sido publicado para a versão/arquitetura em uso, o script avisa (`[WARN]`) com um caminho manual alternativo em vez de travar a instalação.
- O Python instalado é o **padrão do Ubuntu** (`python3`), sem PPA de terceiros — 3.13 ou 3.14 no 26.04, 3.12 no 24.04, 3.10 no 22.04, conforme a versão. Se precisar de uma versão específica diferente da padrão do sistema, use o [deadsnakes PPA](https://launchpad.net/~deadsnakes/+archive/ubuntu/ppa) ou `pyenv` manualmente.
- O Node.js é instalado via [NVM](https://github.com/nvm-sh/nvm) (não pelo apt), sempre a última versão **LTS**, e fica disponível assim que o script termina — não é necessário abrir um novo terminal ou rodar `nvm install` manualmente. O plugin `zsh-nvm` do Oh My Zsh reaproveita a mesma instalação.
- Todas as chamadas de `apt-get`/`dpkg` rodam com `DEBIAN_FRONTEND=noninteractive`, evitando que o script trave esperando confirmação em prompts (ex.: reinício de serviços, teclado) durante execuções não assistidas.
- O script **não altera o fuso horário** já configurado na máquina — apenas garante que os locales `en_US.UTF-8`/`pt_BR.UTF-8` estejam gerados e que a sincronização de horário via NTP (`timedatectl set-ntp true`) esteja ativa.

## Estrutura do script

Cada ferramenta é isolada em uma função (`install_*`, `ensure_*`), chamada a partir de `main()`. Para adicionar uma nova ferramenta, crie uma função seguindo o mesmo padrão (checagem de existência + instalação) e adicione a chamada em `main()` ou no grupo relevante (ex.: `install_cli_tools`).

## Licença

Software de código aberto licenciado sob a [MIT license](https://opensource.org/licenses/MIT).