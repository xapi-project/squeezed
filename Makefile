.PHONY: release build install uninstall clean test doc reindent

release:
	jbuilder build @install

build:
	jbuilder build @install --dev

install:
	cp ./_build/default/src/squeezed.exe ./squeezed.native

uninstall:
	rm ./squeezed.native

clean:
	jbuilder clean

test:
	jbuilder runtest

# requires odoc
doc:
	jbuilder build @doc

reindent:
	ocp-indent --inplace **/*.ml*
