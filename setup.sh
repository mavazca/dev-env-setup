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
    ${SUDO} apt-get update -y
    APT_UPDATED=1
    APT_SOURCES_CHANGED=0
  fi
}

is_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
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
    log "Instalando pacotes: ${missing[*]}"
    ${SUDO} apt-get install -y "${missing[@]}"
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

ensure_ondrej_php_repo() {
  if ! grep -Rqs "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    log "Adicionando repositorio ondrej/php..."
    install_apt_packages software-properties-common
    ${SUDO} add-apt-repository -y ppa:ondrej/php
    APT_SOURCES_CHANGED=1
  else
    info "Repositorio ondrej/php ja configurado"
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
    echo "deb [signed-by=${keyring}] https://apt.releases.hashicorp.com ${codename} main" | ${SUDO} tee "${source_file}" >/dev/null
    APT_SOURCES_CHANGED=1
  else
    info "Repositorio HashiCorp ja configurado"
  fi
}

prepare_environment() {
  log "Preparando ambiente base..."
  install_apt_packages curl git vim lsb-release unzip zip jq dos2unix gnupg ca-certificates apt-transport-https build-essential fonts-firacode
  ensure_ondrej_php_repo
  apt_update_once
}

install_php_versions() {
  log "Instalando PHP 8.3 e 8.4 (com extensoes)..."
  install_apt_packages \
    php8.3 php8.3-common php8.3-cli php8.3-gd php8.3-mysql php8.3-curl php8.3-intl php8.3-mbstring php8.3-bcmath php8.3-imap php8.3-xml php8.3-zip php8.3-bz2 php8.3-xdebug php8.3-redis php8.3-soap php8.3-sqlite3 php8.3-pgsql \
    php8.4 php8.4-common php8.4-cli php8.4-gd php8.4-mysql php8.4-curl php8.4-intl php8.4-mbstring php8.4-bcmath php8.4-imap php8.4-xml php8.4-zip php8.4-bz2 php8.4-xdebug php8.4-redis php8.4-soap php8.4-sqlite3 php8.4-pgsql

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

generate_ssh_key() {
  local ssh_pub="${TARGET_HOME}/.ssh/id_rsa.pub"
  if [[ ! -f "${ssh_pub}" ]]; then
    log "Gerando chave SSH para ${TARGET_USER}..."
    run_as_target_user 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t rsa -f ~/.ssh/id_rsa -q -N ""'
  else
    info "Chave SSH ja existe em ${ssh_pub}"
  fi
}

install_kubernetes_tools() {
  if ! command_exists kubectl; then
    log "Instalando kubectl..."
    curl -fsSLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
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
    log "Instalando hetzner-k3s..."
    ${SUDO} wget -q https://github.com/vitobotta/hetzner-k3s/releases/download/v2.6.0/hetzner-k3s-linux-amd64 -O /usr/local/bin/hetzner-k3s
    ${SUDO} chmod +x /usr/local/bin/hetzner-k3s
  else
    info "hetzner-k3s ja instalado"
  fi

  if ! command_exists hcloud; then
    log "Instalando hcloud CLI..."
    curl -fsSLO https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz
    ${SUDO} tar -C /usr/local/bin --no-same-owner -xzf hcloud-linux-amd64.tar.gz hcloud
    rm -f hcloud-linux-amd64.tar.gz
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
  ${SUDO} dpkg -i "${deb_file}" || ${SUDO} apt-get install -f -y
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

main() {
  echo -e "${GREEN}=============================================${NC}"
  echo -e "${GREEN}  INICIANDO SETUP UNIFICADO DO AMBIENTE${NC}"
  echo -e "${GREEN}=============================================${NC}"

  prepare_environment
  install_php_versions
  install_composer_and_laravel
  install_zsh_stack
  install_yarn
  generate_ssh_key
  install_kubernetes_tools
  configure_kube_aliases_and_direnv
  install_aws_cli
  install_session_manager_plugin
  install_terraform

  echo -e "${GREEN}=============================================${NC}"
  echo -e "${GREEN}  SETUP FINALIZADO COM SUCESSO${NC}"
  echo -e "${GREEN}=============================================${NC}"
  info "Usuario configurado: ${TARGET_USER}"
  info "Abra um novo terminal para carregar alteracoes de shell."
}

main "$@"
