all:
	./build.sh
install:
	./build.sh install
run:
	./build.sh run
dmg:
	./build.sh dmg
universal:
	./build.sh universal
clean:
	rm -rf build .build
.PHONY: all install run dmg universal clean
