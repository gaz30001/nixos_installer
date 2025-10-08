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
  echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo ./nixos_install.sh)${RESET}"
  exit 1
fi

echo -e "${GREEN}--- Интерактивный установщик NixOS ---${RESET}"
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
read -p "Введите имя диска (например, sda или nvme0n1): " DISK
DISK="/dev/${DISK}"
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
echo "Диск: ${DISK}"
echo "Схема: ${BOOT_TYPE}"
echo "Хост: ${HOSTNAME}"
echo "Пользователь: ${USERNAME}"
echo "Часовой пояс: ${TIMEZONE}"
echo "Видеодрайвер: ${driver}"
read -p "Все верно? Нажмите Enter для начала форматирования..."

# --- Разметка и форматирование ---
echo -e "\n${YELLOW}--> Форматирование диска ${DISK}...${RESET}"
# Уничтожаем старую таблицу разделов
wipefs -a "${DISK}"
sgdisk --zap-all "${DISK}"

if [[ "${BOOT_TYPE}" == "UEFI" ]]; then
    # GPT / UEFI
    parted -s "${DISK}" -- mklabel gpt
    parted -s "${DISK}" -- mkpart ESP fat32 1MiB 513MiB
    parted -s "${DISK}" -- set 1 esp on
    parted -s "${DISK}" -- mkpart primary btrfs 513MiB 100%
    BOOT_PART="${DISK}1"
    ROOT_PART="${DISK}2"
    mkfs.fat -F 32 -n BOOT "${BOOT_PART}"
else
    # MBR / BIOS
    parted -s "${DISK}" -- mklabel msdos
    parted -s "${DISK}" -- mkpart primary btrfs 1MiB 100%
    parted -s "${DISK}" -- set 1 boot on
    ROOT_PART="${DISK}1"
fi

mkfs.btrfs -L NIXOS "${ROOT_PART}"
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

# Формирование блока конфигурации для видеодрайвера
case ${VIDEO_DRIVER} in
    1) VIDEO_CONFIG="services.xserver.videoDrivers = [ \"amdgpu\" ];";;
    2) VIDEO_CONFIG="services.xserver.videoDrivers = [ \"intel\" ];";;
    3) VIDEO_CONFIG="services.xserver.videoDrivers = [ \"nvidia\" ];";;
    4) VIDEO_CONFIG="services.xserver.videoDrivers = [ \"nouveau\" ];";;
    5) VIDEO_CONFIG="services.xserver.videoDrivers = [ \"modesetting\" ];";;
esac

# Формирование блока конфигурации для загрузчика
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

# Создание и запись файла configuration.nix
cat << EOF > /mnt/etc/nixos/configuration.nix
{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # --- Загрузчик ---
  ${BOOTLOADER_CONFIG}

  # --- Ядро и микрокод ---
  boot.kernelPackages = pkgs.linuxPackages_zen;
  # Раскомментируйте нужную строку для вашего процессора
  hardware.cpu.amd.updateMicrocode = true;
  # hardware.cpu.intel.updateMicrocode = true;

  # --- Сеть ---
  networking.hostName = "${HOSTNAME}";
  networking.networkmanager.enable = true;

  # --- Локализация ---
  time.timeZone = "${TIMEZONE}";
  i18n.defaultLocale = "ru_RU.UTF-8";
  console = {
    font = "ter-v16n";
    keyMap = "ru";
  };

  # --- Пользователь ---
  users.users.${USERNAME} = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.zsh;
    initialPassword = "${PASSWORD}";
  };
  programs.zsh.enable = true;
  security.sudo.enable = true;
  security.sudo.wheelNeedsPassword = false; # Для удобства

  # --- Графическая подсистема ---
  services.xserver.enable = true;
  services.xserver.layout = "us,ru";
  services.xserver.xkbOptions = "grp:alt_shift_toggle";
  services.xserver.windowManager.bspwm.enable = true;
  ${VIDEO_CONFIG}

  # --- Звук ---
  sound.enable = true;
  hardware.pulseaudio.enable = true;

  # --- Установка пакетов ---
  environment.systemPackages = with pkgs; [
    # Основы
    git curl wget sudo p7zip unrar zip unzip tree stow
    # Разработка
    go nodejs gcc cmake gdb (python3.withPackages(ps: [ ps.pyalsa ]))
    # Терминал и утилиты
    alacritty ranger zsh neovim xclip gpick gparted scrot xarchiver xdotool yad shellcheck shfmt
    # Графическое окружение
    xorg.xinit pcmanfm feh sxhkd polybar dunst libnotify qutebrowser zathura
    # Шрифты (добавляем отдельно)
    # Аудио и мультимедиа
    pavucontrol pulseaudio-alsa alsa-plugins alsa-tools alsa-utils ffmpeg pamixer
    # Утилиты для устройств
    btrfs-progs dosfstools libmtp gvfs-mtp mtpfs android-udev-rules
  ];

  # --- Шрифты ---
  fonts.packages = with pkgs; [
    terminus_font
    (nerdfonts.override { fonts = [ "JetBrainsMono", "FiraCode", "Iosevka" ]; })
  ];
  
  # --- Разрешение для работы не-Nix бинарников ---
  programs.mtr.enable = true;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  # Версия системы
  system.stateVersion = "23.05"; # Используйте версию вашего ISO
}
EOF

echo -e "${GREEN}Файл configuration.nix успешно создан.${RESET}"

# --- Установка системы ---
echo -e "\n${YELLOW}--> Запуск установки NixOS. Это может занять много времени...${RESET}"
nixos-install --no-root-passwd

echo -e "\n${GREEN}--- УСТАНОВКА ЗАВЕРШЕНА ---${RESET}"
echo -e "Теперь вы можете перезагрузить систему."
echo -e "После перезагрузки войдите под пользователем ${YELLOW}${USERNAME}${RESET}."
echo -e "Не забудьте создать файлы конфигурации для bspwm, sxhkd и .xinitrc в вашей домашней директории."

read -p "Нажмите Enter для размонтирования файловых систем и перезагрузки..."

umount -R /mnt
reboot

