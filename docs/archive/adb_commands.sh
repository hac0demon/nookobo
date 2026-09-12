adb shell "mkdir -p /data/linuxroot /data/syncthing/notes /data/books"
adb push scripts/boot_linux.sh /data/boot_linux.sh
adb shell "chmod 755 /data/boot_linux.sh"
adb push build/deploy_payload.tar.gz /data/
adb shell "tar -xzf /data/deploy_payload.tar.gz -C /data/linuxroot/"
adb shell "rm /data/deploy_payload.tar.gz"