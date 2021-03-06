PACKAGE := $(shell grep '^Package:' DESCRIPTION | sed -E 's/^Package:[[:space:]]+//')
RSCRIPT = Rscript --no-init-file
CONTEXT_SOURCE_PATH=${PWD}

all: install

test:
	CONTEXT_SOURCE_PATH=${CONTEXT_SOURCE_PATH} ${RSCRIPT} -e 'library(methods); devtools::test()'

roxygen:
	@mkdir -p man
	${RSCRIPT} -e "library(methods); devtools::document()"

install:
	R CMD INSTALL .

build:
	R CMD build .

check: build
	CONTEXT_SOURCE_PATH=${CONTEXT_SOURCE_PATH} _R_CHECK_CRAN_INCOMING_=FALSE R CMD check --as-cran --no-manual `ls -1tr ${PACKAGE}*gz | tail -n1`
	@rm -f `ls -1tr ${PACKAGE}*gz | tail -n1`
	@rm -rf ${PACKAGE}.Rcheck

README.md: README.Rmd
	Rscript -e "options(warnPartialMatchArgs=FALSE); knitr::knit('$<')"
	sed -i.bak 's/[[:space:]]*$$//' README.md
	rm -f $@.bak myfile.json

clean:
	rm -f ${PACKAGE}_*.tar.gz
	rm -rf ${PACKAGE}.Rcheck

vignettes/src/context.Rmd: vignettes/src/context.R
	${RSCRIPT} -e 'library(sowsear); sowsear("$<", output="$@")'

vignettes/context.Rmd: vignettes/src/context.Rmd
	cd vignettes/src && CONTEXT_SOURCE_PATH=${CONTEXT_SOURCE_PATH} ${RSCRIPT} -e 'knitr::knit("context.Rmd")'
	mv vignettes/src/context.md $@
	sed -i.bak 's/[[:space:]]*$$//' $@
	rm -f $@.bak

vignettes_install: vignettes/context.Rmd
	${RSCRIPT} -e 'library(methods); devtools::build_vignettes()'

vignettes:
	rm -f vignettes/context.Rmd
	make vignettes_install

staticdocs:
	@mkdir -p inst/staticdocs
	Rscript -e "library(methods); staticdocs::build_site()"
	rm -f vignettes/*.html
	@rmdir inst/staticdocs
website: staticdocs
	./update_web.sh

.PHONY: all test document install vignettes
