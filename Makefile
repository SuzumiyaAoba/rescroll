EMACS ?= emacs

.PHONY: check compile test benchmark clean

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile rescroll.el

check: compile test

test:
	$(EMACS) -Q --batch -L . -l test/rescroll-test.el -f ert-run-tests-batch-and-exit

benchmark: compile
	$(EMACS) -Q --batch -L . -l bench-rescroll.el

clean:
	rm -f rescroll.elc
