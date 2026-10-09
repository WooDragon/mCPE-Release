# Included only by the r5s-outdoor device hook, before KernelPackage evaluation.
# Default prepare (including every original package patch) runs before this hook.
MCPE_MT76_FAIL_STOP_DIR := $(CURDIR)/mcpe-fail-stop

define Build/Prepare/MCPEFailStop
	(cd "$(PKG_BUILD_DIR)" && sha256sum --strict -c "$(MCPE_MT76_FAIL_STOP_DIR)/source.sha256")
	patch --batch --forward --fuzz=0 -p1 -d "$(PKG_BUILD_DIR)" < "$(MCPE_MT76_FAIL_STOP_DIR)/990-mt7921-pcie-recovery-fail-stop.patch"
endef

Hooks/Prepare/Post += Build/Prepare/MCPEFailStop
