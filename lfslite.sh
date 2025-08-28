#!/usr/bin/env bash
# lfslite.sh — constrói e gerencia um sistema "Linux From Scratch" simples usando receitas e hooks
# Objetivo: ferramenta única, colorida, com spinner, logs, registry e operações de build/install/remove.
# Requisitos: bash >= 4, coreutils, curl, git, tar, xz, zstd (opcional), unzip (para .zip), patch, make, gcc, fakeroot (opcional)
# Licença: MIT
set -o pipefail

############################################
# 0) CONFIGURAÇÃO (pode ser sobrescrita via env ou .env)
############################################
: "${ROOTFS:=/opt/lfslite/root}"          # destino final de instalação
: "${REPO:=./recipes}"                    # onde ficam as receitas (base, extras, x11, desktop)
: "${WORK:=./work}"                       # diretório de trabalho para compilar
: "${DIST:=./dist}"                       # onde armazenar downloads (arquivos fonte/patches)
: "${BUILD:=./build}"                     # área temporária por pacote (DESTDIR)
: "${DB:=./var/lfslite/db}"               # manifest/registro de instalações
: "${LOGS:=./var/lfslite/logs}"           # logs por ação/pacote
: "${JOBS:=$(nproc 2>/dev/null || echo 2)}" # paralelismo padrão
: "${FAKEROOT:=auto}"                     # auto|yes|no — usar fakeroot se disponível
: "${COLOR:=auto}"                        # auto|always|never
: "${SPINNER:=yes}"                       # spinner ligado/desligado
: "${DEFAULT_CATEGORY:=base}"             # categoria padrão ao criar receita
: "${EDITOR:=vi}"

# Arquivo opcional .env
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source ./.env
fi

############################################
# 1) UI — cores, emojis, spinner
############################################
_supports_color() {
  [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]
}
if [[ $COLOR == always ]] || { [[ $COLOR == auto ]] && _supports_color; }; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)";
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)";
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN="";
fi

info()    { echo -e "${BLUE}ℹ${RESET}  $*"; }
success() { echo -e "${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
err()     { echo -e "${RED}✖${RESET}  $*"; }

# Logging helpers
_ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
logfile_for() { mkdir -p "$LOGS"; echo "$LOGS/$(date +%Y%m%d-%H%M%S)-$1.log"; }
logrun() { # logrun <tag> <cmd...>
  local tag=$1; shift
  local logf; logf=$(logfile_for "$tag")
  ("$@") &> >(tee -a "$logf")
}

spinner_run() { # spinner_run <label> <cmd...>
  local label=$1; shift
  if [[ $SPINNER != yes ]]; then
    info "$label"; "$@"
    return $?
  fi
  info "$label"
  ("$@") &
  local pid=$!
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local i=0
  while kill -0 $pid 2>/dev/null; do
    printf "\r${DIM}%s${RESET} %s" "${frames[i]}" "$label"
    i=$(( (i + 1) % 10 ))
    sleep 0.1
  done
  wait $pid; local rc=$?
  printf "\r" # limpar linha
  if [[ $rc -eq 0 ]]; then success "$label"; else err "$label (rc=$rc)"; fi
  return $rc
}

die() { err "$*"; exit 1; }

############################################
# 2) Estruturas / helpers
############################################
setup_dirs() {
  mkdir -p "$ROOTFS" "$REPO" "$WORK" "$DIST" "$BUILD" "$DB" "$LOGS"
  mkdir -p "$REPO/base" "$REPO/extras" "$REPO/x11" "$REPO/desktop"
}

have() { command -v "$1" >/dev/null 2>&1; }

choose_fakeroot() {
  case "$FAKEROOT" in
    yes) echo 1 ;;
    no)  echo 0 ;;
    auto) have fakeroot && echo 1 || echo 0 ;;
  esac
}

############################################
# 3) Formato de receita
############################################
# Cada receita é um arquivo bash em $REPO/<cat>/<nome>.recipe com variáveis:
# NAME, VERSION, URL (ou GIT), SHA256 (opcional), ARCHIVE (opcional), PATCHES=(... caminhos/URLs ...),
# BUILD_SYSTEM=autotools|cmake|meson|make
# CONFIG_OPTS=(...)
# MAKE_OPTS=(...)
# INSTALL_OPTS=(...)
# DESTDIR_INSTALL=yes|no (padrão: yes)
# BINARIES=(/usr/bin/foo /usr/bin/bar) — para instalações binárias simples (copiar do workdir)
# HOOKS opcional: arquivos executáveis em $RECIPE_DIR/hooks/{pre_configure,configure,pre_install,install,post_install,post_remove}

load_recipe() { # load_recipe <path>
  local path=$1
  [[ -f $path ]] || die "Receita não encontrada: $path"
  # shellcheck disable=SC1090
  source "$path"
  RECIPE_FILE="$path"
  RECIPE_DIR="$(dirname "$path")"
  : "${NAME:?NAME não definido na receita}"
  : "${VERSION:?VERSION não definido na receita}"
  PKGID="${NAME}-${VERSION}"
  SRC_BASENAME="${ARCHIVE:-${URL##*/}}"
  SRC_TARBALL="$DIST/$SRC_BASENAME"
  WORKDIR="$WORK/$PKGID"
  BUILDDIR="$WORKDIR/build"
  PKGDEST="$BUILD/$PKGID" # DESTDIR
  : "${DESTDIR_INSTALL:=yes}"
  : "${BUILD_SYSTEM:=autotools}"
}

manifest_path() { echo "$DB/$NAME.manifest"; }
meta_path()      { echo "$DB/$NAME.meta"; }
installed_p()    { [[ -f $(manifest_path) ]]; }

############################################
# 4) Download, extração, patches
############################################
sha256_ok() { # sha256_ok <file> <expected>
  local f=$1 exp=$2
  [[ -z $exp ]] && return 0
  local got
  if have sha256sum; then got=$(sha256sum "$f" | awk '{print $1}'); else got=$(shasum -a 256 "$f" | awk '{print $1}'); fi
  [[ "$got" == "$exp" ]]
}

fetch_sources() { # usa URL (http/https) ou GIT
  if [[ -n ${URL:-} ]]; then
    mkdir -p "$DIST"
    if [[ ! -f $SRC_TARBALL ]]; then
      spinner_run "Baixando $SRC_BASENAME" curl -L --fail -o "$SRC_TARBALL" "$URL" || die "Falha no download"
    else
      info "Artefato já existe em $SRC_TARBALL"
    fi
    [[ -n ${SHA256:-} ]] && sha256_ok "$SRC_TARBALL" "$SHA256" || [[ -z ${SHA256:-} ]] || die "SHA256 não confere"
  elif [[ -n ${GIT:-} ]]; then
    mkdir -p "$WORK"
    local dest="$WORK/$NAME-src"
    if [[ -d $dest/.git ]]; then
      spinner_run "Atualizando git $NAME" git -C "$dest" pull --ff-only || die "git pull falhou"
    else
      spinner_run "Clonando $GIT" git clone --depth 1 "$GIT" "$dest" || die "git clone falhou"
    fi
    WORKDIR="$dest" # compila direto
  else
    die "Receita sem URL ou GIT"
  fi
}

extract_sources() {
  mkdir -p "$WORK"
  [[ -n ${GIT:-} ]] && { info "Fonte via git, pulando extração"; return 0; }
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"
  case "$SRC_TARBALL" in
    *.tar.gz|*.tgz)   spinner_run "Extraindo tar.gz" tar -xzf "$SRC_TARBALL" -C "$WORKDIR" --strip-components=1 ;;
    *.tar.bz2|*.tbz)  spinner_run "Extraindo tar.bz2" tar -xjf "$SRC_TARBALL" -C "$WORKDIR" --strip-components=1 ;;
    *.tar.xz)         spinner_run "Extraindo tar.xz" tar -xJf "$SRC_TARBALL" -C "$WORKDIR" --strip-components=1 ;;
    *.tar.zst)        spinner_run "Extraindo tar.zst" tar --zstd -xf "$SRC_TARBALL" -C "$WORKDIR" --strip-components=1 ;;
    *.zip)            spinner_run "Extraindo zip" unzip -q "$SRC_TARBALL" -d "$WORKDIR" && shopt -s dotglob nullglob && mv "$WORKDIR"/*/* "$WORKDIR"/ 2>/dev/null || true ;;
    *.gz)             spinner_run "Descompactando .gz" gunzip -c "$SRC_TARBALL" > "$WORKDIR/$(basename "${SRC_TARBALL%.gz}")" ;;
    *.xz)             spinner_run "Descompactando .xz" xz -dc "$SRC_TARBALL" > "$WORKDIR/$(basename "${SRC_TARBALL%.xz}")" ;;
    *.bz2)            spinner_run "Descompactando .bz2" bzip2 -dc "$SRC_TARBALL" > "$WORKDIR/$(basename "${SRC_TARBALL%.bz2}")" ;;
    *) die "Formato não suportado: $SRC_TARBALL" ;;
  esac
}

apply_patches() {
  [[ ${#PATCHES[@]:-0} -eq 0 ]] && { info "Sem patches"; return 0; }
  pushd "$WORKDIR" >/dev/null || die "WORKDIR inválido"
  for p in "${PATCHES[@]}"; do
    local patchfile="$p"
    # Se for URL, baixar para DIST
    if [[ "$p" =~ ^https?:// ]]; then
      patchfile="$DIST/$(basename "$p")"
      [[ -f $patchfile ]] || spinner_run "Baixando patch $(basename "$p")" curl -L --fail -o "$patchfile" "$p"
    elif [[ ! -f $patchfile ]]; then
      # tentar relativo ao RECIPE_DIR
      patchfile="$RECIPE_DIR/$(basename "$p")"
    fi
    [[ -f $patchfile ]] || die "Patch não encontrado: $p"
    spinner_run "Aplicando patch $(basename "$patchfile")" patch -p1 < "$patchfile" || die "Falha ao aplicar patch"
  done
  popd >/dev/null || true
}

############################################
# 5) Build: configure/compile
############################################
run_hook() { # run_hook <name>
  local hook="$RECIPE_DIR/hooks/$1"
  if [[ -x $hook ]]; then
    spinner_run "Hook $1" "$hook" "$WORKDIR" "$ROOTFS" "$PKGDEST"
  fi
}

configure_step() {
  pushd "$WORKDIR" >/dev/null || die "WORKDIR inválido"
  run_hook pre_configure
  if [[ -x "$RECIPE_DIR/hooks/configure" ]]; then
    spinner_run "Hook configure" "$RECIPE_DIR/hooks/configure" "$WORKDIR" "$ROOTFS" "$PKGDEST"
  else
    case "$BUILD_SYSTEM" in
      autotools)
        mkdir -p "$BUILDDIR"; pushd "$BUILDDIR" >/dev/null || exit 1
        spinner_run "./configure" ../configure --prefix=/usr "${CONFIG_OPTS[@]}" ;;
      cmake)
        mkdir -p "$BUILDDIR"; pushd "$BUILDDIR" >/dev/null || exit 1
        spinner_run "cmake" -S .. -B . -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release "${CONFIG_OPTS[@]}" ;;
      meson)
        mkdir -p "$BUILDDIR"; pushd "$BUILDDIR" >/dev/null || exit 1
        spinner_run "meson setup" meson setup . .. --prefix=/usr "${CONFIG_OPTS[@]}" ;;
      make)
        mkdir -p "$BUILDDIR"; pushd "$WORKDIR" >/dev/null || exit 1
        info "BUILD_SYSTEM=make (sem configure)" ;;
      *) die "BUILD_SYSTEM desconhecido: $BUILD_SYSTEM" ;;
    esac
  fi
  popd >/dev/null || true
}

compile_step() {
  local dir=${BUILDDIR:-$WORKDIR}
  pushd "$dir" >/dev/null || die "Diretório de build inválido"
  case "$BUILD_SYSTEM" in
    autotools|cmake|meson|make)
      spinner_run "Compilando ($JOBS jobs)" make -j"$JOBS" "${MAKE_OPTS[@]}" ;;
    *) die "BUILD_SYSTEM desconhecido: $BUILD_SYSTEM" ;;
  esac
  popd >/dev/null || true
}

############################################
# 6) Instalação (DESTDIR, fakeroot, binários) + Registro/Desinstalação
############################################
preinstall_snapshot() { find "$ROOTFS" -xdev -printf '%p\n' 2>/dev/null | sort > "$WORK/.preinstall.lst"; }
postinstall_snapshot() { find "$ROOTFS" -xdev -printf '%p\n' 2>/dev/null | sort > "$WORK/.postinstall.lst"; }
manifest_from_snapshots() { comm -13 "$WORK/.preinstall.lst" "$WORK/.postinstall.lst" > "$(manifest_path)"; }

install_step() {
  run_hook pre_install
  mkdir -p "$PKGDEST"
  local use_fr=$(choose_fakeroot)
  local dir=${BUILDDIR:-$WORKDIR}

  if [[ ${#BINARIES[@]:-0} -gt 0 ]]; then
    # Instalação simples copiando binários do WORKDIR
    for b in "${BINARIES[@]}"; do
      local rel="${b#/}" ; mkdir -p "$PKGDEST/$(dirname "$rel")"
      cp -av "$WORKDIR/$(basename "$b")" "$PKGDEST/$rel"
    done
  else
    pushd "$dir" >/dev/null || die "Diretório de build inválido"
    if [[ $DESTDIR_INSTALL == yes ]]; then
      spinner_run "make install (DESTDIR)" make DESTDIR="$PKGDEST" install "${INSTALL_OPTS[@]}"
    else
      preinstall_snapshot
      spinner_run "make install (direto)" make install "${INSTALL_OPTS[@]}"
      postinstall_snapshot
      manifest_from_snapshots
    fi
    popd >/dev/null || true
  fi

  # Se usamos DESTDIR, agora promover ao ROOTFS (com fakeroot se disponível)
  if [[ $DESTDIR_INSTALL == yes ]]; then
    mkdir -p "$ROOTFS"
    if [[ $use_fr -eq 1 ]]; then
      spinner_run "fakeroot merge" fakeroot sh -c "cp -a '$PKGDEST'/* '$ROOTFS'/"
    else
      spinner_run "merge arquivos" sh -c "cp -a '$PKGDEST'/* '$ROOTFS'/"
    fi
    # Gerar manifest a partir do DESTDIR
    (cd "$PKGDEST" && find . -type f -o -type l -o -type d | sed 's#^\.##' | sed "s#^#/#") > "$(manifest_path)"
  fi

  # Registro meta
  {
    echo "NAME=$NAME"; echo "VERSION=$VERSION"; echo "DATE=$(_ts)"; echo "RECIPE=$RECIPE_FILE";
  } > "$(meta_path)"

  run_hook install
  run_hook post_install
  success "Instalado ${BOLD}$NAME${RESET} ${DIM}$(manifest_path)$( [[ -s $(manifest_path) ]] && echo " ("$(wc -l <"$(manifest_path)")" arquivos)")${RESET}"
}

remove_pkg() {
  local man; man=$(manifest_path)
  [[ -f $man ]] || die "Pacote não instalado: $NAME"
  # Remover em ordem inversa (arquivos, links, depois diretórios vazios)
  tac "$man" | while read -r p; do
    local path="$ROOTFS$p"
    if [[ -d $path && ! -L $path ]]; then rmdir --ignore-fail-on-non-empty "$path" 2>/dev/null || true
    else rm -f "$path" 2>/dev/null || true
    fi
  done
  run_hook post_remove || true
  rm -f "$man" "$(meta_path)"
  success "Removido $NAME"
}

############################################
# 7) Ações compostas (build sem instalar, build+install, info, limpar)
############################################
build_only() { fetch_sources; extract_sources; apply_patches; configure_step; compile_step; }
full_build_install() { build_only; install_step; }

pkg_info() {
  echo "${BOLD}Pacote:${RESET} $NAME"
  echo "${BOLD}Versão:${RESET} $VERSION"
  echo "${BOLD}Instalado?:${RESET} $(installed_p && echo sim || echo não)"
  local meta; meta=$(meta_path)
  [[ -f $meta ]] && { echo "${BOLD}Meta:${RESET}"; cat "$meta"; }
}

clean_work() { rm -rf "$WORK"/* "$BUILD"/*; success "Limpos: $WORK e $BUILD"; }

############################################
# 8) Toolchain (esqueleto simplificado)
############################################
# Cria diretórios e exporta variáveis para um toolchain LFS (simplificado)
init_toolchain() {
  : "${LFS_TGT:=$(uname -m)-lfslite-linux-gnu}"
  : "${TOOLS:=/opt/lfslite/tools}"
  mkdir -p "$TOOLS" "$ROOTFS" {usr,lib,bin,include} >/dev/null 2>&1 || true
  cat > .toolchain.env <<EOF
export LFS_TGT="$LFS_TGT"
export PATH="$TOOLS/bin:\$PATH"
export CONFIG_SITE="$ROOTFS/usr/share/config.site"
export CC="gcc" CXX="g++"
EOF
  success "Toolchain inicializado. Ative com: ${BOLD}source ./.toolchain.env${RESET}"
}

############################################
# 9) Criar receita (scaffold)
############################################
create_recipe() { # create_recipe <nome> [categoria]
  local name=$1 cat=${2:-$DEFAULT_CATEGORY}
  local dir="$REPO/$cat"
  mkdir -p "$dir/$name/hooks"
  cat > "$dir/$name.recipe" <<'TEMPLATE'
# Exemplo de receita
NAME="hello"
VERSION="2.12"
URL="https://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz"
SHA256="6a9fa5d0b2e1f908a3f2b712f852d6732d97869bc1f67ef9b3c5f2dba7d7f29f"
# GIT="https://git.example/hello.git"
PATCHES=( )
BUILD_SYSTEM=autotools
CONFIG_OPTS=( )
MAKE_OPTS=( )
INSTALL_OPTS=( )
DESTDIR_INSTALL=yes
# BINARIES=(/usr/bin/hello) # para copiar binários do workdir
TEMPLATE
  chmod +x "$dir/$name.recipe"
  success "Receita criada em $dir/$name.recipe"
}

############################################
# 10) CLI
############################################
usage() {
  cat <<USAGE
${BOLD}lfslite.sh${RESET} — constrói/instala/remove pacotes em uma LFS simples usando receitas

${BOLD}Uso:${RESET}
  $0 init                                      # cria estrutura de diretórios
  $0 new <nome> [categoria]                     # cria esqueleto de receita
  $0 fetch <path-receita>                       # baixar fontes
  $0 extract <path-receita>                     # extrair fontes
  $0 patch <path-receita>                       # aplicar patches
  $0 configure <path-receita>                   # configurar
  $0 build <path-receita>                       # compilar (sem instalar)
  $0 install <path-receita>                     # construir e instalar
  $0 remove <path-receita>                      # desinstalar usando manifest
  $0 info <path-receita>                        # informações do pacote
  $0 toolchain init                             # inicializar toolchain básico
  $0 clean                                      # limpar WORK e BUILD

${BOLD}Layout de receitas:${RESET} \$REPO/{base,extras,x11,desktop}/<nome>.recipe
Variáveis do ambiente: ROOTFS, REPO, WORK, DIST, BUILD, DB, LOGS, JOBS, FAKEROOT, COLOR, SPINNER
USAGE
}

main() {
  local cmd=${1:-help}
  case "$cmd" in
    help|-h|--help) usage ;;
    init) setup_dirs; success "Estrutura pronta" ;;
    new) setup_dirs; [[ -z ${2:-} ]] && die "Informe <nome>"; create_recipe "$2" "${3:-}" ;;
    fetch) load_recipe "${2:?Informe receita}"; setup_dirs; fetch_sources ;;
    extract) load_recipe "${2:?Informe receita}"; setup_dirs; extract_sources ;;
    patch) load_recipe "${2:?Informe receita}"; setup_dirs; apply_patches ;;
    configure) load_recipe "${2:?Informe receita}"; setup_dirs; configure_step ;;
    build) load_recipe "${2:?Informe receita}"; setup_dirs; build_only ;;
    install) load_recipe "${2:?Informe receita}"; setup_dirs; full_build_install ;;
    remove) load_recipe "${2:?Informe receita}"; setup_dirs; remove_pkg ;;
    info) load_recipe "${2:?Informe receita}"; setup_dirs; pkg_info ;;
    toolchain) [[ ${2:-} == init ]] && init_toolchain || die "Subcomando desconhecido para toolchain" ;;
    clean) setup_dirs; clean_work ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
