# Device hook: prepend outdoor-backup feed for r5s-outdoor variant.
# Sourced by diy-part1.sh BEFORE 'scripts/feeds update' when DEVICE=r5s-outdoor.
echo 'src-git outdoor https://github.com/WooDragon/outdoor-backup^20aeaf59e96a4e9a704922c3a4007885af4d016f' >>feeds.conf.default
