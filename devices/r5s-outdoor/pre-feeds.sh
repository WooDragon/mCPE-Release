# Device hook: prepend outdoor-backup feed for r5s-outdoor variant.
# Sourced by diy-part1.sh BEFORE 'scripts/feeds update' when DEVICE=r5s-outdoor.
echo 'src-git outdoor https://github.com/WooDragon/outdoor-backup^6d7631fc22416d216edd9d0e057bc9169960436a' >>feeds.conf.default
