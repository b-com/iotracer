build:
	$(MAKE) -C src 

clean:
	$(MAKE) -C src clean

install:
	$(MAKE) -C src install

codecheck:
	$(MAKE) -C src codecheck
	shellcheck $(wildcard scripts/*.sh)
	shellcheck $(filter-out tests/assert.sh, $(wildcard tests/*.sh))
	/usr/bin/python3 -m pyflakes tests/*.py

