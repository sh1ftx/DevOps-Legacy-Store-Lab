#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "========== INÍCIO $(date) =========="

# ---------------- FUNÇÕES ----------------

log() { echo -e "\n[INFO] $1"; }
warn() { echo -e "\n[WARN] $1"; }
fail() { echo -e "\n[ERRO] $1"; exit 1; }

retry() {
    local tries=$1; shift
    local count=0
    until "$@"; do
        count=$((count+1))
        if [ $count -ge $tries ]; then return 1; fi
        warn "Tentativa $count falhou..."
        sleep 3
    done
}

has() { command -v "$1" >/dev/null 2>&1; }

# ---------------- DETECÇÃO ----------------

if [ -f /etc/arch-release ]; then
    DISTRO="arch"
elif [ -f /etc/debian_version ]; then
    DISTRO="debian"
else
    DISTRO="unknown"
fi

log "Sistema: $DISTRO"

rm -rf loja-virtual-devops || true

# ---------------- ARCH ----------------

install_arch() {
    sudo pacman -Syu --noconfirm
    sudo pacman -S --noconfirm git curl dkms linux-headers virtualbox virtualbox-host-dkms

    if ! has vagrant; then
        if has yay; then
            yay -S --noconfirm vagrant
        else
            sudo pacman -S --needed base-devel git
            git clone https://aur.archlinux.org/yay.git
            cd yay && makepkg -si --noconfirm && cd ..
            yay -S --noconfirm vagrant
        fi
    fi

    sudo dkms autoinstall || true
}

install_debian() {
    sudo apt update
    sudo apt install -y virtualbox virtualbox-dkms vagrant git curl
}

# ---------------- DOCKER FIX ----------------

fix_docker() {
    sudo systemctl enable --now docker || true
    sudo usermod -aG docker $USER || true

    if ! groups | grep -q docker; then
        warn "Sem permissão docker → usando sudo"
        DOCKER="sudo docker"
    else
        DOCKER="docker"
    fi
}

install_docker() {
    log "Instalando Docker..."

    if [ "$DISTRO" = "arch" ]; then
        sudo pacman -S --noconfirm docker docker-compose
    else
        sudo apt install -y docker.io docker-compose
    fi

    fix_docker
}

run_docker() {
    log "Rodando Docker fallback..."

    cat > docker-compose.yml <<EOF
services:
  db:
    image: mysql:8
    environment:
      MYSQL_ROOT_PASSWORD: 12345
      MYSQL_DATABASE: loja_schema
      MYSQL_USER: vinicius
      MYSQL_PASSWORD: 12345
    ports:
      - "3306:3306"

  web:
    image: tomcat:9
    ports:
      - "8080:8080"
EOF

    $DOCKER compose up -d

    sleep 20

    curl -I http://localhost:8080 || fail "Docker falhou"

    log "Docker OK → http://localhost:8080"
    exit 0
}

# ---------------- INSTALAR BASE ----------------

if [ "$DISTRO" = "arch" ]; then
    install_arch || warn "Arch falhou"
elif [ "$DISTRO" = "debian" ]; then
    install_debian
else
    install_docker
    run_docker
fi

# ---------------- VALIDAR VIRTUALIZAÇÃO ----------------

if ! has vagrant || ! has vboxmanage; then
    warn "Sem VM → fallback Docker"
    install_docker
    run_docker
fi

# ---------------- VAGRANT MODERNO ----------------

mkdir loja-virtual-devops
cd loja-virtual-devops

cat > Vagrantfile <<EOF
Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/bionic64"

  config.vm.define :app do |app|
    app.vm.network :private_network, ip: "192.168.56.10"

    app.vm.provision "shell", inline: <<-SHELL
      apt-get update -y
      apt-get install -y openjdk-8-jdk maven mysql-server tomcat9 git curl

      systemctl enable mysql
      systemctl start mysql

      mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS loja_schema;
CREATE USER IF NOT EXISTS 'vinicius'@'%' IDENTIFIED BY '12345';
GRANT ALL PRIVILEGES ON loja_schema.* TO 'vinicius'@'%';
FLUSH PRIVILEGES;
SQL

      cd /home/vagrant
      git clone https://github.com/dtsato/loja-virtual-devops.git
      cd loja-virtual-devops

      mvn clean install -DskipTests

      cp target/*.war /var/lib/tomcat9/webapps/ROOT.war

      systemctl restart tomcat9
    SHELL
  end
end
EOF

log "Subindo VM..."
if ! retry 2 vagrant up; then
    warn "VM falhou → Docker"
    cd ..
    install_docker
    run_docker
fi

sleep 30

# ---------------- TESTES ----------------

log "Testando banco..."

retry 3 mysql -h 192.168.56.10 -u vinicius -p12345 \
    -e "SHOW DATABASES;" || warn "Banco falhou"

log "Testando web..."

if ! retry 5 curl -I http://192.168.56.10:8080; then
    warn "Web falhou → Docker"
    cd ..
    install_docker
    run_docker
fi

# ---------------- FINAL ----------------

echo "======================================"
echo "✅ FUNCIONANDO"
echo "VM: http://192.168.56.10:8080"
echo "Fallback: http://localhost:8080"
echo "======================================"