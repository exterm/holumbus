# Making FileSystem-Standalone Programs

HOME		= ../../..

SOURCE		= .

GHC_FLAGS	= -Wall -threaded -O2 -hidir $(OUTPUT) -odir $(OUTPUT) -i../../../.
GHC		= ghc $(GHC_FLAGS)

RM_FLAGS	= -rf
RM		= rm $(RM_FLAGS)

PROG		= PickleTest

OUTPUT		= output

all : $(PROG)

#prof : $(PROG).hs
#	[ -d $(OUTPUT) ] || mkdir -p $(OUTPUT)
#	$(RM) $(OUTPUT)/*
#	$(GHC) -prof -auto-all -ignore-package Holumbus -i../../source/ --make -o $(PROG)_p $(PROG).hs

% : %.hs
	[ -d $(OUTPUT) ] || mkdir -p $(OUTPUT)
	$(RM) $(OUTPUT)/*
	$(GHC) --make -o $@ $<

clean :
	$(RM) $(PROG) $(OUTPUT) *.xml
	
