# amneziawg-mipsel
интерактивный менеджер AmneziaWG для OpenWRT
На роутере:
opkg update && opkg install git-core
git clone https://github.com/<you>/openwrt-awg-manager.git
cd openwrt-awg-manager
chmod +x awg.sh
./awg.sh
В меню выбери «Установить/обновить», вставь свой конфиг, при желании — «Подобрать MTU», «Автозапуск On», «Запустить VPN».

Проверка:
./awg.sh  пункт 11 «Проверить IP/маршрут»
Если нужно — добавлю опции «резервный конфиг», «Telegram-уведомления» или «список исключений (split-tunnel)».
