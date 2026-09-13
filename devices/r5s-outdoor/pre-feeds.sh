# Device hook: prepend outdoor-backup feed for r5s-outdoor variant.
# Sourced by diy-part1.sh BEFORE 'scripts/feeds update' when DEVICE=r5s-outdoor.
echo 'src-git outdoor https://github.com/WooDragon/outdoor-backup^f8cb4d857b5916604875a71c71cb071c008838d6' >>feeds.conf.default
