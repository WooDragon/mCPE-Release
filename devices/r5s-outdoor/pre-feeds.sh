# Device hook: prepend outdoor-backup feed for r5s-outdoor variant.
# Sourced by diy-part1.sh BEFORE 'scripts/feeds update' when DEVICE=r5s-outdoor.
echo 'src-git outdoor https://github.com/WooDragon/outdoor-backup^b1ab8499089a3d8b603a92d9a055c0cbd52c29a5' >>feeds.conf.default
