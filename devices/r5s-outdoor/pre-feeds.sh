# Device hook: prepend outdoor-backup feed for r5s-outdoor variant.
# Sourced by diy-part1.sh BEFORE 'scripts/feeds update' when DEVICE=r5s-outdoor.
echo 'src-git outdoor https://github.com/WooDragon/outdoor-backup^ea28208cde76b3c0372db0d1de1c7abf5feb2657' >>feeds.conf.default
