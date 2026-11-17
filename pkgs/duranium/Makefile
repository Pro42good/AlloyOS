PREFIX ?= /usr
DESTDIR ?=

.PHONY: all test unit qemu fixture syntax clean install

all: test

unit:
	sh tests/run-unit.sh

fixture:
	sh qemu/build-fixture.sh

qemu: fixture
	sh tests/qemu/run-suite.sh

test: unit qemu

syntax:
	@set -e; \
	for f in src/bin/duranium src/lib/*.sh src/initramfs/init src/recovery/init \
	         src/root/sbin-init src/migrations/*.sh qemu/*.sh tests/*.sh \
	         tests/unit/*.sh tests/qemu/*.sh tests/qemu/scenarios/*.sh; do \
	    sh -n "$$f" || exit 1; \
	done; \
	printf 'syntax OK\n'

clean:
	rm -rf qemu/out tests/.tmp
	rm -f qemu/*.log

install:
	install -Dm755 src/bin/duranium "$(DESTDIR)$(PREFIX)/bin/duranium"
	for f in src/lib/*.sh; do \
	    install -Dm644 "$$f" "$(DESTDIR)$(PREFIX)/lib/duranium/$$(basename $$f)"; \
	done
	install -Dm644 src/etc/duranium.conf "$(DESTDIR)/etc/duranium/duranium.conf"
	install -Dm644 src/etc/state.conf "$(DESTDIR)/etc/duranium/state.conf"
	install -Dm644 src/etc/profile "$(DESTDIR)/etc/duranium/profile"
	install -Dm644 src/etc/hardware-target "$(DESTDIR)/etc/duranium/hardware-target"
	install -Dm644 src/etc/state-schema "$(DESTDIR)/etc/duranium/state-schema"
	install -Dm644 src/etc/health.d/10-core.sh "$(DESTDIR)/etc/duranium/health.d/10-core.sh"
	install -Dm755 src/initramfs/init "$(DESTDIR)$(PREFIX)/share/duranium/initramfs/init"
	install -Dm644 src/etc/initramfs.conf "$(DESTDIR)$(PREFIX)/share/duranium/initramfs/initramfs.conf"
	install -Dm755 src/recovery/init "$(DESTDIR)$(PREFIX)/share/duranium/recovery/init"
	install -Dm755 src/root/sbin-init "$(DESTDIR)$(PREFIX)/share/duranium/fixture/sbin-init"
	install -Dm755 src/migrations/1-to-2.sh "$(DESTDIR)$(PREFIX)/share/duranium/examples/migrations/1-to-2.sh"
	install -Dm644 src/migrations/1-to-2.conf "$(DESTDIR)$(PREFIX)/share/duranium/examples/migrations/1-to-2.conf"
	for f in docs/*.md; do \
	    install -Dm644 "$$f" "$(DESTDIR)$(PREFIX)/share/duranium/docs/$$(basename $$f)"; \
	done
	for f in contrib/alloy-core/*; do \
	    install -Dm644 "$$f" "$(DESTDIR)$(PREFIX)/share/duranium/contrib/alloy-core/$$(basename $$f)"; \
	done
