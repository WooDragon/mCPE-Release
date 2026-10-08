include $(TOPDIR)/rules.mk

PKG_NAME:=exiftool
PKG_VERSION:=13.59
PKG_RELEASE:=1

PKG_SOURCE:=Image-ExifTool-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://downloads.sourceforge.net/project/exiftool
PKG_HASH:=668ea3acececb7235fbd0f4900e72d5f12c9b07e5c778fd36cb1e9b5828fd65a
PKG_BUILD_DIR:=$(BUILD_DIR)/Image-ExifTool-$(PKG_VERSION)

PKG_LICENSE:=GPL-1.0-or-later Artistic-1.0-Perl
PKG_LICENSE_FILES:=README

include $(INCLUDE_DIR)/package.mk
# Pure Perl: only use the interpreter's ABI-independent module search directory.
# perlmod.mk's MakeMaker/cross-compiler machinery is unnecessary for source copies.
include $(TOPDIR)/feeds/packages/lang/perl/perlver.mk

define Package/exiftool
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Read and write image metadata
  URL:=https://exiftool.org/
  DEPENDS:=+perl +perlbase-essential +perlbase-file +perlbase-integer +perlbase-time
endef

define Package/exiftool/description
  ExifTool CLI and complete Image::ExifTool module tree for reading and writing
  image, audio and video metadata. Optional upstream compression and hashing
  extensions are not required for the core metadata reader/writer.
endef

# No configure/build step: there is no native code or generated runtime content.
define Build/Configure
endef

define Build/Compile
endef

define Package/exiftool/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/lib/perl5/$(PERL_VERSION2)
	sed '1s|.*|#!/usr/bin/perl|' $(PKG_BUILD_DIR)/exiftool > $(1)/usr/bin/exiftool
	chmod 0755 $(1)/usr/bin/exiftool
	$(CP) $(PKG_BUILD_DIR)/lib/Image $(PKG_BUILD_DIR)/lib/File $(1)/usr/lib/perl5/$(PERL_VERSION2)/
	find $(1)/usr/lib/perl5/$(PERL_VERSION2) -name '*.pod' -delete
	rm -f $(1)/usr/lib/perl5/$(PERL_VERSION2)/Image/ExifTool/README
endef

$(eval $(call BuildPackage,exiftool))
