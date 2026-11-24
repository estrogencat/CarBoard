ARCHS = arm64 arm64e
TARGET = iphone:16.5:16.5

THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = carboard
carboard_FILES = $(wildcard src/hooks/*.xm) $(wildcard src/*.mm)
carboard_CFLAGS = -Wno-deprecated-declarations
carboard_FRAMEWORKS = IOSurface


include $(THEOS_MAKE_PATH)/tweak.mk

after-carboard-stage::
	mkdir -p $(THEOS_STAGING_DIR)/DEBIAN/
	cp postinst_postrm $(THEOS_STAGING_DIR)/DEBIAN/postinst
	cp postinst_postrm $(THEOS_STAGING_DIR)/DEBIAN/postrm
	chmod +x $(THEOS_STAGING_DIR)/DEBIAN/post*
	find $(THEOS_STAGING_DIR) -name ".DS_Store" -delete

after-install::
	install.exec "killall -9 SpringBoard CarPlay Preferences"

SUBPROJECTS += carboardprefs

include $(THEOS_MAKE_PATH)/aggregate.mk
