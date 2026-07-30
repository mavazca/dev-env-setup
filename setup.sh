#!/usr/bin/env bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

info() {
  echo -e "${BLUE}[INFO] $1${NC}"
}

warn() {
  echo -e "${YELLOW}[WARN] $1${NC}"
}

error() {
  echo -e "${RED}[ERRO] $1${NC}"
}

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
  TARGET_USER="${SUDO_USER:-root}"
else
  if ! command -v sudo >/dev/null 2>&1; then
    error "sudo nao encontrado. Rode como root ou instale sudo."
    exit 1
  fi
  SUDO="sudo"
  TARGET_USER="${USER}"
fi

TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
if [[ -z "${TARGET_HOME}" ]]; then
  error "Nao foi possivel identificar HOME do usuario ${TARGET_USER}."
  exit 1
fi

# Evita que apt-get/dpkg fiquem esperando input interativo (ex.: prompts de
# reinicio de servico, configuracao de teclado) quando o script roda de forma
# nao assistida (CI, cloud-init, curl | bash).
export DEBIAN_FRONTEND=noninteractive
APT_GET="${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get"

APT_UPDATED=0
APT_SOURCES_CHANGED=0

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_as_target_user() {
  local cmd="$1"
  if [[ "$(id -un)" == "${TARGET_USER}" ]]; then
    bash -lc "${cmd}"
  else
    su - "${TARGET_USER}" -c "${cmd}"
  fi
}

apt_update_once() {
  if [[ "${APT_UPDATED}" -eq 0 || "${APT_SOURCES_CHANGED}" -eq 1 ]]; then
    log "Atualizando cache de pacotes..."
    ${APT_GET} update -y
    APT_UPDATED=1
    APT_SOURCES_CHANGED=0
  fi
}

is_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

apt_pkg_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

install_apt_packages() {
  local missing=()
  local pkg

  for pkg in "$@"; do
    if ! is_pkg_installed "${pkg}"; then
      missing+=("${pkg}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    apt_update_once

    local to_install=()
    local skipped=()
    for pkg in "${missing[@]}"; do
      if apt_pkg_available "${pkg}"; then
        to_install+=("${pkg}")
      else
        skipped+=("${pkg}")
      fi
    done

    if [[ "${#skipped[@]}" -gt 0 ]]; then
      warn "Pacotes ainda indisponiveis no repositorio e ignorados (ex.: extensoes muito novas): ${skipped[*]}"
    fi

    if [[ "${#to_install[@]}" -gt 0 ]]; then
      log "Instalando pacotes: ${to_install[*]}"
      ${APT_GET} install -y "${to_install[@]}"
    fi
  else
    info "Pacotes ja instalados: $*"
  fi
}

ensure_line_in_file() {
  local line="$1"
  local file="$2"
  touch "${file}"
  if ! grep -Fxq "${line}" "${file}"; then
    echo "${line}" >> "${file}"
  fi
}

ensure_php_sury_repo() {
  # O ppa:ondrej/php nao publica pacotes para o Ubuntu 26.04 (resolute); o
  # proprio mantenedor (Ondrej Sury) migrou para o repositorio
  # packages.sury.org/php, que cobre resolute, noble e jammy.
  local keyring="/usr/share/keyrings/debsuryorg-archive-keyring.gpg"
  local source_file="/etc/apt/sources.list.d/php.list"

  install_apt_packages lsb-release ca-certificates curl

  if [[ ! -f "${keyring}" ]]; then
    log "Configurando chave do repositorio PHP (Sury)..."
    curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
    ${SUDO} env DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/debsuryorg-archive-keyring.deb
    rm -f /tmp/debsuryorg-archive-keyring.deb
  fi

  if [[ ! -f "${source_file}" ]] || ! grep -q "packages.sury.org" "${source_file}"; then
    log "Adicionando repositorio PHP (Sury)..."
    echo "deb [signed-by=${keyring}] https://packages.sury.org/php/ $(lsb_release -sc) main" | ${SUDO} tee "${source_file}" >/dev/null
    APT_SOURCES_CHANGED=1
  else
    info "Repositorio PHP (Sury) ja configurado"
  fi
}

ensure_yarn_repo() {
  local keyring="/etc/apt/keyrings/yarn.gpg"
  local source_file="/etc/apt/sources.list.d/yarn.list"

  if [[ ! -f "${keyring}" ]]; then
    log "Configurando chave do repositorio Yarn..."
    ${SUDO} mkdir -p /etc/apt/keyrings
    curl -fsSL https://dl.yarnpkg.com/debian/pubkey.gpg | ${SUDO} gpg --dearmor -o "${keyring}"
  fi

  if [[ ! -f "${source_file}" ]] || ! grep -q "dl.yarnpkg.com" "${source_file}"; then
    log "Adicionando repositorio Yarn..."
    echo "deb [signed-by=${keyring}] https://dl.yarnpkg.com/debian/ stable main" | ${SUDO} tee "${source_file}" >/dev/null
    APT_SOURCES_CHANGED=1
  else
    info "Repositorio Yarn ja configurado"
  fi
}

ensure_hashicorp_repo() {
  local keyring="/etc/apt/keyrings/hashicorp-archive-keyring.gpg"
  local source_file="/etc/apt/sources.list.d/hashicorp.list"

  if [[ ! -f "${keyring}" ]]; then
    log "Configurando chave do repositorio HashiCorp..."
    ${SUDO} mkdir -p /etc/apt/keyrings
    curl -fsSL https://apt.releases.hashicorp.com/gpg | ${SUDO} gpg --dearmor -o "${keyring}"
  fi

  if [[ ! -f "${source_file}" ]] || ! grep -q "apt.releases.hashicorp.com" "${source_file}"; then
    log "Adicionando repositorio HashiCorp..."
    local codename
    codename="$(lsb_release -cs)"
    # O repositorio da HashiCorp pode demorar a publicar pacotes para
    # codenames muito novos (ex.: 'resolute' no lancamento do Ubuntu
    # 26.04); nesse caso caimos para o 'noble' (24.04), que e
    # binario-compativel e funciona normalmente no 26.04.
    if ! curl -fsSL -o /dev/null "https://apt.releases.hashicorp.com/dists/${codename}/Release"; then
      warn "Repositorio HashiCorp ainda nao publica pacotes para '${codename}'. Usando 'noble' como fallback."
      codename="noble"
    fi
    echo "deb [signed-by=${keyring}] https://apt.releases.hashicorp.com ${codename} main" | ${SUDO} tee "${source_file}" >/dev/null
    APT_SOURCES_CHANGED=1
  else
    info "Repositorio HashiCorp ja configurado"
  fi
}

configure_locale_timezone() {
  log "Configurando locale e timezone..."
  install_apt_packages locales tzdata

  # Gera os locales sem forcar qual fica ativo por padrao no sistema.
  if ! locale -a 2>/dev/null | grep -qi "^en_US.utf8$"; then
    ${SUDO} locale-gen en_US.UTF-8
  fi
  if ! locale -a 2>/dev/null | grep -qi "^pt_BR.utf8$"; then
    ${SUDO} locale-gen pt_BR.UTF-8
  fi

  if [[ ! -f /etc/default/locale ]] || ! grep -q "^LANG=" /etc/default/locale 2>/dev/null; then
    ${SUDO} update-locale LANG=en_US.UTF-8
  fi

  # Nao alteramos o fuso horario ja configurado na maquina (pode ter sido
  # definido na instalacao do SO); apenas garantimos sincronizacao via NTP.
  if command_exists timedatectl; then
    ${SUDO} timedatectl set-ntp true >/dev/null 2>&1 || true
    info "Timezone atual: $(timedatectl show -p Timezone --value 2>/dev/null)"
  fi
}

configure_git() {
  log "Configurando Git (defaults)..."

  run_as_target_user "git config --global init.defaultBranch main" || true
  run_as_target_user "git config --global pull.rebase false" || true
  if command_exists code; then
    run_as_target_user "git config --global core.editor 'code --wait'" || true
  else
    run_as_target_user "git config --global core.editor nano" || true
  fi

  local has_name has_email
  has_name="$(run_as_target_user 'git config --global user.name' 2>/dev/null || true)"
  has_email="$(run_as_target_user 'git config --global user.email' 2>/dev/null || true)"

  if [[ -n "${has_name}" && -n "${has_email}" ]]; then
    info "Git user.name/user.email ja configurados (${has_name} <${has_email}>)"
    return
  fi

  if [[ -t 0 ]]; then
    local git_name git_email
    if [[ -z "${has_name}" ]]; then
      read -rp "Nome para o Git (git config user.name): " git_name
      if [[ -n "${git_name}" ]]; then
        run_as_target_user "git config --global user.name $(printf '%q' "${git_name}")"
      fi
    fi
    if [[ -z "${has_email}" ]]; then
      read -rp "E-mail para o Git (git config user.email): " git_email
      if [[ -n "${git_email}" ]]; then
        run_as_target_user "git config --global user.email $(printf '%q' "${git_email}")"
      fi
    fi
  else
    warn "Execucao nao interativa: git user.name/user.email nao configurados."
    warn "Configure manualmente com: git config --global user.name \"Seu Nome\" && git config --global user.email \"voce@exemplo.com\""
  fi
}

install_db_clients() {
  log "Instalando clientes de banco de dados (mysql, postgresql, redis)..."
  install_apt_packages mysql-client postgresql-client redis-tools
}

prepare_environment() {
  log "Preparando ambiente base..."
  install_apt_packages curl git vim nano lsb-release unzip zip jq dos2unix gnupg ca-certificates apt-transport-https build-essential fonts-firacode
  configure_locale_timezone
  configure_git
  install_db_clients
  ensure_php_sury_repo
  apt_update_once
}

install_cli_tools() {
  install_github_cli
  ensure_local_bin_in_path
  install_claude_code_cli
  install_codex_cli
  install_kiro_cli
  install_opencode_cli
}

install_php_versions() {
  log "Instalando PHP 8.4 e 8.5 (com extensoes)..."
  install_apt_packages \
    php8.4 php8.4-common php8.4-cli php8.4-gd php8.4-mysql php8.4-curl php8.4-intl php8.4-mbstring php8.4-bcmath php8.4-imap php8.4-xml php8.4-zip php8.4-bz2 php8.4-xdebug php8.4-redis php8.4-soap php8.4-sqlite3 php8.4-pgsql \
    php8.5 php8.5-common php8.5-cli php8.5-gd php8.5-mysql php8.5-curl php8.5-intl php8.5-mbstring php8.5-bcmath php8.5-imap php8.5-xml php8.5-zip php8.5-bz2 php8.5-xdebug php8.5-redis php8.5-soap php8.5-sqlite3 php8.5-pgsql

  if [[ -x /usr/bin/php8.4 ]]; then
    ${SUDO} update-alternatives --set php /usr/bin/php8.4 || true
  fi
}

install_composer_and_laravel() {
  if ! command_exists composer; then
    log "Instalando Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    ${SUDO} php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  else
    info "Composer ja instalado"
  fi

  if run_as_target_user "composer global show laravel/installer >/dev/null 2>&1"; then
    info "Laravel Installer ja instalado (global)"
  else
    log "Instalando Laravel Installer globalmente..."
    run_as_target_user "COMPOSER_ALLOW_SUPERUSER=1 composer global require laravel/installer --no-interaction"
  fi
}

install_zsh_stack() {
  install_apt_packages zsh

  local ohmyzsh_dir="${TARGET_HOME}/.oh-my-zsh"
  local zshrc="${TARGET_HOME}/.zshrc"

  if [[ ! -d "${ohmyzsh_dir}" ]]; then
    log "Instalando Oh-My-Zsh para ${TARGET_USER}..."
    run_as_target_user "RUNZSH=no CHSH=no sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\""
  else
    info "Oh-My-Zsh ja instalado para ${TARGET_USER}"
  fi

  local plugin_root="${ohmyzsh_dir}/custom/plugins"
  if [[ ! -d "${plugin_root}/zsh-autosuggestions" ]]; then
    run_as_target_user "git clone https://github.com/zsh-users/zsh-autosuggestions ${plugin_root}/zsh-autosuggestions"
  fi
  if [[ ! -d "${plugin_root}/zsh-completions" ]]; then
    run_as_target_user "git clone https://github.com/zsh-users/zsh-completions ${plugin_root}/zsh-completions"
  fi
  if [[ ! -d "${plugin_root}/zsh-nvm" ]]; then
    run_as_target_user "git clone https://github.com/lukechilds/zsh-nvm ${plugin_root}/zsh-nvm"
  fi
  if [[ ! -d "${plugin_root}/F-Sy-H" ]]; then
    run_as_target_user "git clone https://github.com/z-shell/F-Sy-H.git ${plugin_root}/F-Sy-H"
  fi

  if [[ -f "${zshrc}" ]]; then
    ${SUDO} sed -i -E 's/^plugins=\(.*\)$/plugins=(laravel composer git ssh-agent zsh-autosuggestions zsh-completions zsh-nvm F-Sy-H)/' "${zshrc}" || true
  else
    run_as_target_user "touch ${zshrc}"
  fi

  ensure_line_in_file "ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20" "${zshrc}"
  ensure_line_in_file "ZSH_AUTOSUGGEST_STRATEGY=(history completion)" "${zshrc}"
  ensure_line_in_file "ZSH_AUTOSUGGEST_USE_ASYNC=1" "${zshrc}"
  ensure_line_in_file "TERM=xterm-256color" "${zshrc}"

  local dracula_theme_dir="${ohmyzsh_dir}/custom/themes/dracula"
  if [[ ! -f "${ohmyzsh_dir}/custom/themes/dracula.zsh-theme" ]]; then
    log "Instalando tema Dracula para ZSH..."
    run_as_target_user "git clone https://github.com/dracula/zsh.git ${dracula_theme_dir}"
    run_as_target_user "mv ${dracula_theme_dir}/dracula.zsh-theme ${ohmyzsh_dir}/custom/themes/"
    run_as_target_user "mv ${dracula_theme_dir}/lib ${ohmyzsh_dir}/custom/themes/"
    run_as_target_user "rm -rf ${dracula_theme_dir}"
  else
    info "Tema Dracula ja instalado"
  fi

  if command_exists chsh && [[ "$(getent passwd "${TARGET_USER}" | cut -d: -f7)" != "/usr/bin/zsh" ]]; then
    log "Definindo ZSH como shell padrao para ${TARGET_USER}..."
    ${SUDO} chsh -s /usr/bin/zsh "${TARGET_USER}" || warn "Nao foi possivel alterar shell padrao automaticamente"
  fi
}

install_yarn() {
  if command_exists yarn; then
    info "Yarn ja instalado"
    return
  fi

  ensure_yarn_repo
  apt_update_once
  install_apt_packages yarn
}

install_node() {
  # Instala o NVM (mesmo gerenciador usado pelo plugin zsh-nvm) e ja deixa
  # uma versao LTS do Node pronta, para o Yarn funcionar de imediato sem
  # depender do usuario rodar 'nvm install' manualmente na primeira vez.
  local nvm_version="v0.40.6"
  local nvm_dir="${TARGET_HOME}/.nvm"

  if [[ ! -s "${nvm_dir}/nvm.sh" ]]; then
    log "Instalando NVM (${nvm_version})..."
    run_as_target_user "export NVM_DIR=\"${nvm_dir}\"; curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_version}/install.sh | bash"
  else
    info "NVM ja instalado"
  fi

  if run_as_target_user "export NVM_DIR=\"${nvm_dir}\"; . \"${nvm_dir}/nvm.sh\" >/dev/null 2>&1; command -v node >/dev/null 2>&1"; then
    info "Node.js ja instalado via NVM"
  else
    log "Instalando Node.js (ultima LTS) via NVM..."
    run_as_target_user "export NVM_DIR=\"${nvm_dir}\"; . \"${nvm_dir}/nvm.sh\"; nvm install --lts"
  fi

  run_as_target_user "export NVM_DIR=\"${nvm_dir}\"; . \"${nvm_dir}/nvm.sh\"; nvm alias default 'lts/*'" >/dev/null 2>&1 || true
}

generate_ssh_key() {
  local ssh_pub="${TARGET_HOME}/.ssh/id_ed25519.pub"
  if [[ ! -f "${ssh_pub}" ]]; then
    log "Gerando chave SSH (ed25519) para ${TARGET_USER}..."
    run_as_target_user 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -q -N ""'
  else
    info "Chave SSH ja existe em ${ssh_pub}"
  fi
}

install_kubernetes_tools() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      error "Arquitetura nao suportada para ferramentas Kubernetes: ${arch}"
      return 1
      ;;
  esac

  if ! command_exists kubectl; then
    log "Instalando kubectl (${arch})..."
    curl -fsSLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/${arch}/kubectl"
    chmod +x kubectl
    ${SUDO} mv kubectl /usr/local/bin/
  else
    info "kubectl ja instalado"
  fi

  if ! command_exists helm; then
    log "Instalando Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  else
    info "Helm ja instalado"
  fi

  if ! command_exists hetzner-k3s; then
    log "Instalando hetzner-k3s (${arch})..."
    ${SUDO} wget -q "https://github.com/vitobotta/hetzner-k3s/releases/latest/download/hetzner-k3s-linux-${arch}" -O /usr/local/bin/hetzner-k3s
    ${SUDO} chmod +x /usr/local/bin/hetzner-k3s
  else
    info "hetzner-k3s ja instalado"
  fi

  if ! command_exists hcloud; then
    log "Instalando hcloud CLI (${arch})..."
    curl -fsSLO "https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-${arch}.tar.gz"
    ${SUDO} tar -C /usr/local/bin --no-same-owner -xzf "hcloud-linux-${arch}.tar.gz" hcloud
    rm -f "hcloud-linux-${arch}.tar.gz"
  else
    info "hcloud CLI ja instalado"
  fi

  if [[ ! -d /opt/kubectx ]]; then
    log "Clonando kubectx/kubens..."
    ${SUDO} git clone https://github.com/ahmetb/kubectx /opt/kubectx
  else
    info "kubectx ja clonado em /opt/kubectx"
  fi
  ${SUDO} ln -sf /opt/kubectx/kubectx /usr/local/bin/kubectx
  ${SUDO} ln -sf /opt/kubectx/kubens /usr/local/bin/kubens
}

configure_kube_aliases_and_direnv() {
  install_apt_packages direnv

  local aliases_file="${TARGET_HOME}/.kube_aliases"
  if [[ ! -f "${aliases_file}" ]]; then
    log "Criando arquivo de aliases Kubernetes..."
    cat > /tmp/.kube_aliases <<'EOF'
# Aliases Kubernetes e Helm
alias k='kubectl'
alias kx='kubectx'
alias kns='kubens'
alias kpo='kubectl get pods -o wide'
alias kna='kubectl get namespaces'
alias kd='kubectl describe'
alias kdp='kubectl describe pod'
alias kdns='kubectl describe namespace'
alias klogs='kubectl logs'
alias kg='kubectl get'
alias kfollow='kubectl logs -f'
alias h='helm'
alias kls='kubectl get namespaces -o name | sed "s/namespace\///g"'
alias kpwd='kubectl config view --minify | grep namespace'
alias kcontext='kubectl config current-context'
alias kpors='kubectl get pods --sort-by=".status.containerStatuses[0].restartCount"'
alias kpv='kubectl get pv --sort-by=.spec.capacity.storage'
alias knips='kubectl get nodes -o jsonpath="{.items[*].status.addresses[?(@.type==\"ExternalIP\")].address}"'
alias hlapps='helm list -A'

function kbash() {
  kubectl exec -it "$1" -- /bin/bash
}

function kcheck() {
  kubectl exec -it "$1" -- /bin/bash -c "$2"
}

function kroot() {
  kubectl config set-context "$(kubectl config current-context)" --namespace=default
}
EOF
    ${SUDO} mv /tmp/.kube_aliases "${aliases_file}"
    ${SUDO} chown "${TARGET_USER}:${TARGET_USER}" "${aliases_file}"
  else
    info "Arquivo ${aliases_file} ja existe. Mantendo conteudo atual."
  fi
  dos2unix "${aliases_file}" >/dev/null 2>&1 || true

  local bashrc="${TARGET_HOME}/.bashrc"
  local zshrc="${TARGET_HOME}/.zshrc"
  ensure_line_in_file 'eval "$(direnv hook bash)"' "${bashrc}"
  ensure_line_in_file 'source ~/.kube_aliases' "${bashrc}"
  ensure_line_in_file 'eval "$(direnv hook zsh)"' "${zshrc}"
  ensure_line_in_file 'source ~/.kube_aliases' "${zshrc}"
}

install_aws_cli() {
  if command_exists aws; then
    info "AWS CLI ja instalada"
    return
  fi

  log "Instalando AWS CLI v2..."
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *)
      error "Arquitetura nao suportada para instalacao automatica da AWS CLI: ${arch}"
      return 1
      ;;
  esac

  local aws_zip="/tmp/awscliv2.zip"
  rm -rf /tmp/aws
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "${aws_zip}"
  unzip -q -o "${aws_zip}" -d /tmp
  ${SUDO} /tmp/aws/install
  rm -rf /tmp/aws "${aws_zip}"
}

install_session_manager_plugin() {
  if command_exists session-manager-plugin; then
    info "AWS Session Manager Plugin ja instalado"
    return
  fi

  log "Instalando AWS Session Manager Plugin..."
  local arch
  local deb_url
  arch="$(uname -m)"
  case "${arch}" in
    x86_64)
      deb_url="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb"
      ;;
    aarch64|arm64)
      deb_url="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb"
      ;;
    *)
      error "Arquitetura nao suportada para Session Manager Plugin: ${arch}"
      return 1
      ;;
  esac

  local deb_file="/tmp/session-manager-plugin.deb"
  curl -fsSL "${deb_url}" -o "${deb_file}"
  ${SUDO} env DEBIAN_FRONTEND=noninteractive dpkg -i "${deb_file}" || ${APT_GET} install -f -y
  rm -f "${deb_file}"
}

install_terraform() {
  if command_exists terraform; then
    info "Terraform CLI ja instalado"
    return
  fi

  ensure_hashicorp_repo
  apt_update_once
  install_apt_packages terraform
}

install_java() {
  # A partir do Ubuntu 25.04/25.10 e 26.04 (resolute), o openjdk-25-jdk ja
  # esta disponivel diretamente nos repositorios oficiais (main/universe).
  # Em 22.04 (jammy) e 24.04 (noble) o pacote pode estar apenas em
  # 'universe' (ou ainda nao ter sido publicado); garantimos o repositorio
  # 'universe' habilitado e deixamos o install_apt_packages avisar (WARN) e
  # seguir em frente caso o pacote ainda nao exista para a versao/arquitetura.
  if command_exists javac && javac --version 2>/dev/null | grep -q "^javac 25"; then
    info "Java 25 (JDK) ja instalado"
  else
    log "Instalando Java 25 (OpenJDK)..."
    if command_exists add-apt-repository; then
      ${SUDO} add-apt-repository -y universe >/dev/null 2>&1 || true
    fi
    install_apt_packages openjdk-25-jdk
  fi

  if command_exists javac; then
    local jhome
    jhome="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
    local bashrc="${TARGET_HOME}/.bashrc"
    local zshrc="${TARGET_HOME}/.zshrc"
    ensure_line_in_file "export JAVA_HOME=${jhome}" "${bashrc}"
    ensure_line_in_file "export JAVA_HOME=${jhome}" "${zshrc}"
  else
    warn "openjdk-25-jdk nao esta disponivel no repositorio desta versao/arquitetura do Ubuntu."
    warn "Verifique com 'apt-cache policy openjdk-25-jdk' ou instale manualmente (ex.: Temurin/Adoptium ou .deb da Oracle)."
  fi
}

install_maven() {
  if command_exists mvn; then
    info "Maven ja instalado"
    return
  fi

  log "Instalando Maven..."
  install_apt_packages maven

  if ! command_exists mvn; then
    warn "maven nao esta disponivel no repositorio desta versao/arquitetura do Ubuntu."
    warn "Verifique com 'apt-cache policy maven' ou instale manualmente a partir de https://maven.apache.org/download.cgi"
  fi
}

install_python() {
  # Usamos o Python 3 padrao do proprio Ubuntu (main), sem PPA de terceiros,
  # seguindo o mesmo espirito do install_java: a versao "default" da
  # distribuicao ja e recente o suficiente (3.13/3.14 no 26.04) e recebe
  # atualizacoes de seguranca via apt normalmente.
  log "Instalando Python 3, pip, venv e pipx..."
  install_apt_packages python3 python3-pip python3-venv python3-dev pipx

  if command_exists pipx; then
    run_as_target_user "pipx ensurepath" >/dev/null 2>&1 || true
  fi
}

ensure_github_cli_repo() {
  local keyring="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
  local source_file="/etc/apt/sources.list.d/github-cli.list"

  ${SUDO} mkdir -p -m 755 /etc/apt/keyrings

  if [[ ! -f "${keyring}" ]]; then
    log "Configurando chave do repositorio GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | ${SUDO} tee "${keyring}" >/dev/null
    ${SUDO} chmod go+r "${keyring}"
  fi

  if [[ ! -f "${source_file}" ]] || ! grep -q "cli.github.com" "${source_file}"; then
    log "Adicionando repositorio GitHub CLI..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://cli.github.com/packages stable main" | ${SUDO} tee "${source_file}" >/dev/null
    APT_SOURCES_CHANGED=1
  else
    info "Repositorio GitHub CLI ja configurado"
  fi
}

install_github_cli() {
  if command_exists gh; then
    info "GitHub CLI ja instalado"
    return
  fi

  log "Instalando GitHub CLI..."
  ensure_github_cli_repo
  apt_update_once
  install_apt_packages gh
}

ensure_local_bin_in_path() {
  # Claude Code, Codex CLI, OpenCode CLI e Kiro CLI instalam o binario em
  # ~/.local/bin (ou ~/.opencode/bin, no caso do OpenCode) para o usuario
  # alvo. Garantimos que esses diretorios estejam no PATH mesmo em shells
  # nao interativas (ex.: cron, CI, SSH sem shell de login completo).
  local bashrc="${TARGET_HOME}/.bashrc"
  local zshrc="${TARGET_HOME}/.zshrc"
  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  local opencode_path_line='export PATH="$HOME/.opencode/bin:$PATH"'

  ensure_line_in_file "${path_line}" "${bashrc}"
  ensure_line_in_file "${path_line}" "${zshrc}"
  ensure_line_in_file "${opencode_path_line}" "${bashrc}"
  ensure_line_in_file "${opencode_path_line}" "${zshrc}"
}

install_claude_code_cli() {
  if run_as_target_user 'command -v claude >/dev/null 2>&1 || [[ -x "${HOME}/.local/bin/claude" ]]'; then
    info "Claude Code CLI ja instalado para ${TARGET_USER}"
    return
  fi

  log "Instalando Claude Code CLI (instalador nativo) para ${TARGET_USER}..."
  run_as_target_user "curl -fsSL https://claude.ai/install.sh | bash"
}

install_codex_cli() {
  if run_as_target_user 'command -v codex >/dev/null 2>&1 || [[ -x "${HOME}/.local/bin/codex" ]]'; then
    info "Codex CLI ja instalado para ${TARGET_USER}"
    return
  fi

  log "Instalando Codex CLI (OpenAI, instalador nativo) para ${TARGET_USER}..."
  run_as_target_user "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
}

install_opencode_cli() {
  if run_as_target_user 'command -v opencode >/dev/null 2>&1 || [[ -x "${HOME}/.opencode/bin/opencode" ]]'; then
    info "OpenCode CLI ja instalado para ${TARGET_USER}"
    return
  fi

  log "Instalando OpenCode CLI (instalador nativo) para ${TARGET_USER}..."
  run_as_target_user "curl -fsSL https://opencode.ai/install | bash"
}

install_kiro_cli() {
  # O binario instalado se chama "kiro-cli" (nao "kiro") e vai para
  # ~/.local/bin, assim como o Claude Code e o Codex CLI.
  if run_as_target_user 'command -v kiro-cli >/dev/null 2>&1 || [[ -x "${HOME}/.local/bin/kiro-cli" ]]'; then
    info "Kiro CLI ja instalado para ${TARGET_USER}"
    return
  fi

  log "Instalando Kiro CLI (instalador nativo) para ${TARGET_USER}..."
  # O instalador oficial fica em cli.kiro.dev/install (nao em kiro.dev/install*).
  if run_as_target_user "curl -fsSL https://cli.kiro.dev/install | bash"; then
    return
  fi
  warn "Nao foi possivel instalar o Kiro CLI automaticamente a partir de https://cli.kiro.dev/install."
  warn "Verifique o instalador oficial em https://kiro.dev/docs/cli/installation/"
}

main() {
  echo -e "${GREEN}=============================================${NC}"
  echo -e "${GREEN} INICIANDO SETUP UNIFICADO DO AMBIENTE${NC}"
  echo -e "${GREEN}=============================================${NC}"

  prepare_environment
  install_php_versions
  install_composer_and_laravel
  install_zsh_stack
  install_yarn
  install_node
  generate_ssh_key
  install_kubernetes_tools
  configure_kube_aliases_and_direnv
  install_aws_cli
  install_session_manager_plugin
  install_terraform
  install_java
  install_maven
  install_python
  install_cli_tools

  echo -e "${GREEN}=============================================${NC}"
  echo -e "${GREEN} SETUP FINALIZADO COM SUCESSO${NC}"
  echo -e "${GREEN}=============================================${NC}"
  info "Usuario configurado: ${TARGET_USER}"
  info "Abra um novo terminal para carregar alteracoes de shell."
}

main "$@"