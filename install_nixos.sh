#!/usr/bin/env bash

# Выход при любой ошибке
set -e

# Цвета для вывода
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

# Проверка, что скрипт запущен от имени root
if [[ "${EUID}" -ne 0 ]]; then
  echo -e "${RED}Пожалуйста, запустите скрипт с правами root (bash ./nixos_install.sh)${RESET}"
  exit 1
fi

echo -e "${GREEN}--- Интерактивный установщик NixOS (v9 - Nerd Fonts Fix) ---${RESET}"
echo -e "${YELLOW}Этот скрипт сотрет все данные на выбранном диске!${RESET}"
read -p "Вы уверены, что хотите продолжить? (y/N): " CONFIRM
if [[ "${CONFIRM}" != "y" ]]; then
  echo "Установка отменена."
  exit 0
fi

# --- Сбор информации от пользователя ---

# 1. Выбор диска
echo -e "\n${GREEN}1. Выбор диска для установки:${RESET}"
lsblk -d -o NAME,SIZE,MODEL
read -p "Введите имя диска (например, sda или nvme0n1): " DISK_NAME
DISK="/dev/${DISK_NAME}"
if ! lsblk "${DISK}" > /dev/null 2>&1; then
    echo -e "${RED}Диск ${DISK} не найден!${RESET}"
    exit 1
fi

# 2. Выбор схемы разделов (GPT/MBR)
echo -e "\n${GREEN}2. Выбор схемы разделов:${RESET}"
PS3="Выберите тип: "
select part_scheme in "GPT (рекомендуется для UEFI)" "MBR (для старых систем BIOS)"; do
    case ${REPLY} in
        1) BOOT_TYPE="UEFI"; break;;
        2) BOOT_TYPE="BIOS"; break;;
        *) echo "Неверный выбор";;
    esac
done

# 3. Информация о пользователе и системе
echo -e "\n${GREEN}3. Ввод данных:${RESET}"
read -p "Введите имя хоста (имя компьютера): " HOSTNAME
read -p "Введите имя пользователя: " USERNAME
while true; do
    read -s -p "Введите пароль для пользователя ${USERNAME}: " PASSWORD
    echo
    read -s -p "Повторите пароль: " PASSWORD2
    echo
    [ "${PASSWORD}" = "${PASSWORD2}" ] && break
    echo -e "${YELLOW}Пароли не совпадают. Попробуйте снова.${RESET}"
done

# 4. Выбор часового пояса
echo -e "\n${GREEN}4. Выбор региона (часового пояса):${RESET}"
PS3="Выберите ваш регион: "
timezones=("Europe/Moscow" "Europe/Kyiv" "Europe/Minsk" "Asia/Yekaterinburg" "Asia/Tashkent" "Asia/Almaty")
select tz in "${timezones[@]}"; do
    if [[ -n "${tz}" ]]; then
        TIMEZONE=${tz}
        break
    else
        echo "Неверный выбор."
    fi
done

# 5. Выбор видеодрайвера
echo -e "\n${GREEN}5. Выбор видеодрайвера:${RESET}"
PS3="Выберите ваш видеодрайвер: "
drivers=("AMD (открытый, рекомендуется)" "Intel (открытый, рекомендуется)" "NVIDIA (проприетарный)" "NVIDIA (открытый, nouveau)" "modesetting (универсальный)")
select driver in "${drivers[@]}"; do
    VIDEO_DRIVER=${REPLY}
    break
done

# --- Начало установки ---
echo -e "\n${GREEN}--- НАЧАЛО УСТАНОВКИ ---${RESET}"
read -p "Все верно? Нажмите Enter для начала форматирования..."

# --- Разметка и форматирование ---
echo -e "\n${YELLOW}--> Предварительная очистка: отмонтируем все разделы на ${DISK}...${RESET}"
umount -R /mnt &>/dev/null || true
swapoff -a &>/dev/null || true
for part in $(lsblk -lnpo NAME "${DISK}"); do
    if mountpoint -q "${part}"; then
        echo "Отмонтирование ${part}..."
        umount "${part}"
    fi
done
sleep 2

echo -e "\n${YELLOW}--> Форматирование диска ${DISK}...${RESET}"
wipefs -a "${DISK}"
sgdisk --zap-all "${DISK}"

if [[ "${BOOT_TYPE}" == "UEFI" ]]; then
    parted -s "${DISK}" -- mklabel gpt
    parted -s "${DISK}" -- mkpart ESP fat32 1MiB 513MiB
    parted -s "${DISK}" -- set 1 esp on
    parted -s "${DISK}" -- mkpart primary btrfs 513MiB 100%
    BOOT_PART=$(lsblk -plno NAME "${DISK}" | grep "${DISK_NAME}[p]*1")
    ROOT_PART=$(lsblk -plno NAME "${DISK}" | grep "${DISK_NAME}[p]*2")
    mkfs.fat -F 32 -n BOOT "${BOOT_PART}"
else
    parted -s "${DISK}" -- mklabel msdos
    parted -s "${DISK}" -- mkpart primary btrfs 1MiB 100%
    parted -s "${DISK}" -- set 1 boot on
    ROOT_PART=$(lsblk -plno NAME "${DISK}" | grep "${DISK_NAME}[p]*1")
fi

mkfs.btrfs -f -L NIXOS "${ROOT_PART}"
echo -e "${GREEN}Диск отформатирован.${RESET}"

# --- Создание BTRFS подтомов и монтирование ---
echo -e "\n${YELLOW}--> Монтирование файловой системы BTRFS...${RESET}"
mount -t btrfs "${ROOT_PART}" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

BTRFS_OPTS="noatime,compress=zstd:2,ssd,discard=async,space_cache=v2"
mount -o "subvol=@,${BTRFS_OPTS}" "${ROOT_PART}" /mnt
mkdir -p /mnt/home
mount -o "subvol=@home,${BTRFS_OPTS}" "${ROOT_PART}" /mnt/home

if [[ "${BOOT_TYPE}" == "UEFI" ]]; then
    mkdir -p /mnt/boot
    mount "${BOOT_PART}" /mnt/boot
fi
echo -e "${GREEN}Файловая система смонтирована.${RESET}"

# --- Генерация конфигурации NixOS ---
echo -e "\n${YELLOW}--> Генерация configuration.nix...${RESET}"
nixos-generate-config --root /mnt

case ${VIDEO_DRIVER} in
    1) VIDEO_CONFIG="services.xserver.videoDrivers = [ \"amdgpu\" ];";;
    2) VIDEO_CONFIG="services.xserver.videoDrivers = [ \"intel\" ];";;
    3) VIDEO_CONFIG="services.xserver.videoDrivers = [ \"nvidia\" ];";;
    4) VIDEO_CONFIG="services.xserver.videoDrivers = [ \"nouveau\" ];";;
    5) VIDEO_CONFIG="services.xserver.videoDrivers = [ \"modesetting\" ];";;
esac

if [[ "${BOOT_TYPE}" == "UEFI" ]]; then
    BOOTLOADER_CONFIG=$(cat <<EOF
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "nodev";
  boot.loader.grub.efiSupport = true;
  boot.loader.efi.canTouchEfiVariables = true;
EOF
)
else
    BOOTLOADER_CONFIG=$(cat <<EOF
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "${DISK}";
EOF
)
fi

cat << EOF > /mnt/etc/nixos/configuration.nix
{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Разрешаем несвободные пакеты (например, unrar)
  nixpkgs.config.allowUnfree = true;

  ${BOOTLOADER_CONFIG}

  boot.kernelPackages = pkgs.linuxPackages_zen;
  hardware.cpu.amd.updateMicrocode = true;

  networking.hostName = "${HOSTNAME}";
  networking.networkmanager.enable = true;

  time.timeZone = "${TIMEZONE}";
  i18n.defaultLocale = "ru_RU.UTF-8";
  console = { font = "ter-v16n"; keyMap = "ru"; };

  users.users.${USERNAME} = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.zsh;
    initialPassword = "${PASSWORD}";
  };
  programs.zsh.enable = true;
  security.sudo.enable = true;
  security.sudo.wheelNeedsPassword = false;

  services.xserver.enable = true;
  # Обновленная, современная конфигурация клавиатуры
  services.xserver.xkb = {
    layout = "us,ru";
    options = "grp:alt_shift_toggle";
  };
  services.xserver.windowManager.bspwm.enable = true;
  ${VIDEO_CONFIG}

  # Звук (на базе PipeWire, современный стандарт)
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true; # Включает слой совместимости с PulseAudio
  };

  environment.systemPackages = [
    pkgs.git pkgs.curl pkgs.wget pkgs.sudo pkgs.p7zip pkgs.unrar pkgs.zip pkgs.unzip pkgs.tree pkgs.stow
    pkgs.go pkgs.nodejs pkgs.gcc pkgs.cmake pkgs.gdb (pkgs.python3.withPackages(ps: [ ps.pyalsaaudio ]))
    pkgs.alacritty pkgs.ranger pkgs.zsh pkgs.linux-firmware pkgs.neovim pkgs.xclip pkgs.gpick pkgs.gparted pkgs.scrot pkgs.xarchiver pkgs.xdotool pkgs.yad pkgs.shellcheck pkgs.shfmt
    pkgs.xorg.xinit pkgs.pcmanfm pkgs.feh pkgs.sxhkd pkgs.polybar pkgs.dunst pkgs.libnotify pkgs.qutebrowser pkgs.zathura pkgs.nix-index
    pkgs.pavucontrol
    pkgs.alsa-plugins pkgs.alsa-tools pkgs.alsa-utils pkgs.ffmpeg pkgs.pamixer
    pkgs.btrfs-progs pkgs.dosfstools pkgs.libmtp pkgs.gvfs pkgs.mtpfs pkgs.android-udev-rules
  ];

  # ИСПРАВЛЕНИЕ: Новый способ установки Nerd Fonts
  fonts.packages = [
    pkgs.terminus_font
    pkgs.nerd-fonts.jetbrains-mono
    pkgs.nerd-fonts.fira-code
    pkgs.nerd-fonts.iosevka
  ];
  
  programs.mtr.enable = true;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  system.stateVersion = "24.05";
}
EOF
echo -e "${GREEN}Файл configuration.nix успешно создан.${RESET}"

# --- Установка системы ---
echo -e "\n${YELLOW}--> Запуск установки NixOS. Это может занять много времени...${RESET}"
nixos-install --no-root-passwd

echo -e "\n${GREEN}--- УСТАНОВКА ЗАВЕРШЕНА ---${RESET}"
echo -e "Теперь вы можете перезагрузить систему."
read -p "Нажмите Enter для размонтирования файловых систем и перезагрузки..."

umount -R /mnt
reboot
