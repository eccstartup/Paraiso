doc:
	cabal configure
	cabal install
	cabal haddock "--haddock-options=--source-base=src/ --source-module=src/%{MODULE/./-}.html --source-entity=src/%{MODULE/./-}.html#%N"