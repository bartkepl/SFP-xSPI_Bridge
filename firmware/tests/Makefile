# Host tests of the SFP-xSPI bridge library (gcc, C11).
#   make            build and run the tests
#   make clean

LIB     = ../sfp_bridge
CC     ?= gcc
CFLAGS  = -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Wconversion -Wshadow -Werror \
          -I. -I$(LIB)/include -I$(LIB)/src
LDLIBS  = -lm
OUT     = build

SRC     = test_sfpb.c mock_bridge.c $(LIB)/src/sfp_bridge.c $(LIB)/src/sfpb_sfp.c

all: $(OUT)/test_sfpb
	./$(OUT)/test_sfpb

$(OUT)/test_sfpb: $(SRC) $(wildcard $(LIB)/include/*.h) sfpb_config.h mock_bridge.h | $(OUT)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDLIBS)

$(OUT):
	mkdir -p $(OUT)

clean:
	rm -rf $(OUT)

.PHONY: all clean
